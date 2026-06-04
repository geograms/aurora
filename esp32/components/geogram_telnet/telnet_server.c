/**
 * @file telnet_server.c
 * @brief Telnet server implementation
 *
 * Simple Telnet server that provides CLI access over the network.
 * Uses the esp_console infrastructure for command execution.
 */

#include "telnet_server.h"

#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "esp_console.h"

static const char *TAG = "telnet";

#define TELNET_TASK_STACK   6144
#define TELNET_TASK_PRIO    3
#define TELNET_RX_BUFFER    256
#define TELNET_TX_BUFFER    1024
#define TELNET_PROMPT       "geogram> "

// Telnet protocol bytes
#define TELNET_IAC          255     // Interpret As Command
#define TELNET_WILL         251
#define TELNET_WONT         252
#define TELNET_DO           253
#define TELNET_DONT         254
#define TELNET_ECHO         1
#define TELNET_SGA          3       // Suppress Go Ahead
#define TELNET_LINEMODE     34

static TaskHandle_t s_telnet_task = NULL;
static int s_listen_sock = -1;
static int s_client_sock = -1;
static bool s_running = false;
static uint16_t s_port = TELNET_DEFAULT_PORT;
static char s_client_ip[16] = {0};

// Output buffer for redirected printf
static char s_output_buffer[TELNET_TX_BUFFER];
static size_t s_output_len = 0;

// File handle for stdout redirection
static FILE *s_original_stdout = NULL;

/**
 * @brief Send data to the telnet client
 */
static int telnet_send(const char *data, size_t len)
{
    if (s_client_sock < 0) {
        return -1;
    }

    size_t sent = 0;
    while (sent < len) {
        int ret = send(s_client_sock, data + sent, len - sent, 0);
        if (ret < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                vTaskDelay(pdMS_TO_TICKS(10));
                continue;
            }
            return -1;
        }
        sent += ret;
    }
    return sent;
}

/**
 * @brief Send a string to the telnet client
 */
static int telnet_print(const char *str)
{
    return telnet_send(str, strlen(str));
}

/**
 * @brief Custom write function for stdout redirection to telnet
 */
static ssize_t telnet_stdout_write(void *cookie, const char *buf, size_t size)
{
    if (s_client_sock >= 0 && size > 0) {
        // Convert \n to \r\n for telnet and send directly
        for (size_t i = 0; i < size; i++) {
            if (buf[i] == '\n') {
                send(s_client_sock, "\r\n", 2, 0);
            } else {
                send(s_client_sock, &buf[i], 1, 0);
            }
        }
    }
    return size;
}

/**
 * @brief Redirect stdout to telnet client
 */
static void telnet_redirect_stdout(void)
{
    // Save original stdout
    s_original_stdout = stdout;

    // Create custom FILE stream that writes to telnet
    static cookie_io_functions_t telnet_io = {
        .write = telnet_stdout_write,
        .read = NULL,
        .seek = NULL,
        .close = NULL
    };

    stdout = fopencookie(NULL, "w", telnet_io);
    if (stdout != NULL) {
        setvbuf(stdout, NULL, _IONBF, 0);  // Unbuffered
    } else {
        stdout = s_original_stdout;  // Restore on failure
    }
}

/**
 * @brief Restore stdout to original
 */
static void telnet_restore_stdout(void)
{
    if (s_original_stdout != NULL) {
        if (stdout != s_original_stdout) {
            fclose(stdout);
        }
        stdout = s_original_stdout;
        s_original_stdout = NULL;
    }
}

/**
 * @brief Send telnet negotiation options
 */
static void telnet_negotiate(void)
{
    // Tell client we will echo
    uint8_t will_echo[] = {TELNET_IAC, TELNET_WILL, TELNET_ECHO};
    send(s_client_sock, will_echo, sizeof(will_echo), 0);

    // Tell client we will suppress go-ahead
    uint8_t will_sga[] = {TELNET_IAC, TELNET_WILL, TELNET_SGA};
    send(s_client_sock, will_sga, sizeof(will_sga), 0);

    // Ask client to suppress go-ahead
    uint8_t do_sga[] = {TELNET_IAC, TELNET_DO, TELNET_SGA};
    send(s_client_sock, do_sga, sizeof(do_sga), 0);
}

/**
 * @brief Process telnet protocol bytes
 * @return Number of bytes consumed, or 0 if not a telnet command
 */
static int telnet_process_iac(const uint8_t *buf, size_t len)
{
    if (len < 2 || buf[0] != TELNET_IAC) {
        return 0;
    }

    // Handle escaped IAC
    if (buf[1] == TELNET_IAC) {
        return 2;  // Treat as single 0xFF byte
    }

    // Handle 3-byte commands
    if (len >= 3 && (buf[1] == TELNET_WILL || buf[1] == TELNET_WONT ||
                     buf[1] == TELNET_DO || buf[1] == TELNET_DONT)) {
        // Just acknowledge and ignore options
        return 3;
    }

    // Handle 2-byte commands
    return 2;
}

/**
 * @brief Handle a connected telnet client
 */
static void telnet_handle_client(void)
{
    char line[TELNET_RX_BUFFER];
    size_t line_pos = 0;
    uint8_t rx_buf[64];

    ESP_LOGI(TAG, "Client connected from %s", s_client_ip);

    // Send negotiation
    telnet_negotiate();
    vTaskDelay(pdMS_TO_TICKS(100));

    // Send welcome message
    telnet_print("\r\n");
    telnet_print("╔═══════════════════════════════════════╗\r\n");
    telnet_print("║     Geogram ESP32 Telnet Console      ║\r\n");
    telnet_print("╚═══════════════════════════════════════╝\r\n");
    telnet_print("\r\n");
    telnet_print("Type 'help' for available commands\r\n");
    telnet_print("Type 'exit' or 'quit' to disconnect\r\n");
    telnet_print("\r\n");
    telnet_print(TELNET_PROMPT);

    while (s_running && s_client_sock >= 0) {
        // Receive data with timeout
        struct timeval tv = {.tv_sec = 0, .tv_usec = 100000};  // 100ms
        setsockopt(s_client_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        int len = recv(s_client_sock, rx_buf, sizeof(rx_buf), 0);

        if (len < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;  // Timeout, just loop
            }
            ESP_LOGE(TAG, "recv error: %d", errno);
            break;
        }

        if (len == 0) {
            ESP_LOGI(TAG, "Client disconnected");
            break;
        }

        // Process received bytes
        for (int i = 0; i < len; i++) {
            // Check for telnet commands
            int iac_len = telnet_process_iac(rx_buf + i, len - i);
            if (iac_len > 0) {
                i += iac_len - 1;  // Skip telnet command bytes
                continue;
            }

            uint8_t c = rx_buf[i];

            // Handle special characters
            if (c == '\r' || c == '\n') {
                if (line_pos > 0) {
                    line[line_pos] = '\0';
                    telnet_print("\r\n");

                    // Check for exit commands
                    if (strcmp(line, "exit") == 0 || strcmp(line, "quit") == 0) {
                        telnet_print("Goodbye!\r\n");
                        goto disconnect;
                    }

                    // Redirect stdout to telnet client
                    telnet_redirect_stdout();

                    // Execute command using esp_console
                    int ret;
                    esp_err_t err = esp_console_run(line, &ret);

                    // Restore stdout
                    fflush(stdout);
                    telnet_restore_stdout();

                    if (err == ESP_ERR_NOT_FOUND) {
                        telnet_print("Unknown command: ");
                        telnet_print(line);
                        telnet_print("\r\n");
                        telnet_print("Type 'help' for available commands\r\n");
                    } else if (err == ESP_ERR_INVALID_ARG) {
                        // Empty command - ignore
                    } else if (err != ESP_OK) {
                        char err_msg[64];
                        snprintf(err_msg, sizeof(err_msg), "Error: %s\r\n", esp_err_to_name(err));
                        telnet_print(err_msg);
                    }

                    line_pos = 0;
                }
                telnet_print(TELNET_PROMPT);
            }
            else if (c == 127 || c == 8) {  // Backspace or DEL
                if (line_pos > 0) {
                    line_pos--;
                    telnet_print("\b \b");  // Erase character on screen
                }
            }
            else if (c == 3) {  // Ctrl+C
                telnet_print("^C\r\n");
                line_pos = 0;
                telnet_print(TELNET_PROMPT);
            }
            else if (c == 4) {  // Ctrl+D
                telnet_print("\r\nGoodbye!\r\n");
                goto disconnect;
            }
            else if (c >= 32 && c < 127) {  // Printable ASCII
                if (line_pos < sizeof(line) - 1) {
                    line[line_pos++] = c;
                    // Echo character
                    char echo[2] = {c, 0};
                    telnet_print(echo);
                }
            }
        }
    }

disconnect:
    ESP_LOGI(TAG, "Client session ended");
}

/**
 * @brief Telnet server task
 */
static void telnet_task(void *arg)
{
    struct sockaddr_in server_addr, client_addr;
    socklen_t client_len = sizeof(client_addr);

    // Create socket
    s_listen_sock = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (s_listen_sock < 0) {
        ESP_LOGE(TAG, "Failed to create socket: %d", errno);
        s_running = false;
        vTaskDelete(NULL);
        return;
    }

    // Allow address reuse
    int opt = 1;
    setsockopt(s_listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    // Bind to port
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_addr.s_addr = htonl(INADDR_ANY);
    server_addr.sin_port = htons(s_port);

    if (bind(s_listen_sock, (struct sockaddr *)&server_addr, sizeof(server_addr)) < 0) {
        ESP_LOGE(TAG, "Failed to bind to port %d: %d", s_port, errno);
        close(s_listen_sock);
        s_listen_sock = -1;
        s_running = false;
        vTaskDelete(NULL);
        return;
    }

    // Listen for connections
    if (listen(s_listen_sock, 1) < 0) {
        ESP_LOGE(TAG, "Failed to listen: %d", errno);
        close(s_listen_sock);
        s_listen_sock = -1;
        s_running = false;
        vTaskDelete(NULL);
        return;
    }

    ESP_LOGI(TAG, "Telnet server listening on port %d", s_port);

    while (s_running) {
        // Set timeout for accept
        struct timeval tv = {.tv_sec = 1, .tv_usec = 0};
        setsockopt(s_listen_sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

        // Accept connection
        s_client_sock = accept(s_listen_sock, (struct sockaddr *)&client_addr, &client_len);

        if (s_client_sock < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue;  // Timeout, just loop
            }
            if (s_running) {
                ESP_LOGE(TAG, "Accept failed: %d", errno);
            }
            continue;
        }

        // Store client IP
        inet_ntop(AF_INET, &client_addr.sin_addr, s_client_ip, sizeof(s_client_ip));

        // Handle client
        telnet_handle_client();

        // Close client socket
        close(s_client_sock);
        s_client_sock = -1;
        s_client_ip[0] = '\0';
    }

    // Cleanup
    if (s_client_sock >= 0) {
        close(s_client_sock);
        s_client_sock = -1;
    }
    if (s_listen_sock >= 0) {
        close(s_listen_sock);
        s_listen_sock = -1;
    }

    ESP_LOGI(TAG, "Telnet server stopped");
    vTaskDelete(NULL);
}

esp_err_t telnet_server_start(uint16_t port)
{
    if (s_running) {
        ESP_LOGW(TAG, "Telnet server already running");
        return ESP_OK;
    }

    s_port = port;
    s_running = true;

    BaseType_t ret = xTaskCreate(
        telnet_task,
        "telnet",
        TELNET_TASK_STACK,
        NULL,
        TELNET_TASK_PRIO,
        &s_telnet_task
    );

    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create telnet task");
        s_running = false;
        return ESP_FAIL;
    }

    return ESP_OK;
}

esp_err_t telnet_server_stop(void)
{
    if (!s_running) {
        return ESP_OK;
    }

    s_running = false;

    // Close sockets to unblock accept/recv
    if (s_client_sock >= 0) {
        close(s_client_sock);
        s_client_sock = -1;
    }
    if (s_listen_sock >= 0) {
        close(s_listen_sock);
        s_listen_sock = -1;
    }

    // Wait for task to exit
    vTaskDelay(pdMS_TO_TICKS(200));

    if (s_telnet_task != NULL) {
        s_telnet_task = NULL;
    }

    ESP_LOGI(TAG, "Telnet server stopped");
    return ESP_OK;
}

bool telnet_server_is_running(void)
{
    return s_running;
}

bool telnet_server_client_connected(void)
{
    return s_client_sock >= 0;
}

esp_err_t telnet_server_get_client_ip(char *ip_str)
{
    if (s_client_sock < 0 || s_client_ip[0] == '\0') {
        return ESP_ERR_INVALID_STATE;
    }

    strcpy(ip_str, s_client_ip);
    return ESP_OK;
}
