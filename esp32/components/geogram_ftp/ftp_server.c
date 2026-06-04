/**
 * @file ftp_server.c
 * @brief Minimal FTP server for ESP32 SD card access
 */

#include "ftp_server.h"
#include "sdcard.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "nvs.h"

static const char *TAG = "ftp_server";

// Configuration
#define FTP_TASK_STACK_SIZE     8192
#define FTP_TASK_PRIORITY       5
#define FTP_BUFFER_SIZE         1024
#define FTP_DATA_BUFFER_SIZE    4096
#define FTP_ROOT_DIR            "/sdcard"
#define FTP_MAX_PATH            128
#define FTP_CWD_SIZE            256   // For relative paths (cwd + arg)
#define FTP_FULL_PATH_SIZE      280   // FTP_ROOT_DIR + FTP_CWD_SIZE + slack
#define FTP_FILEPATH_SIZE       540   // FTP_FULL_PATH_SIZE + max filename (255) + 1

// NVS namespace for device password (shared with SSH)
#define NVS_NAMESPACE           "ssh"
#define NVS_KEY_PASSWORD        "password"

// Server state
static bool s_running = false;
static uint16_t s_port = 0;
static TaskHandle_t s_server_task = NULL;
static int s_listen_sock = -1;
static int s_client_sock = -1;
static char s_client_ip[16] = {0};
static char s_password[64] = {0};
static bool s_password_required = false;

// Session state
typedef struct {
    int ctrl_sock;
    int data_sock;
    int pasv_sock;
    char cwd[FTP_MAX_PATH];
    bool logged_in;
    bool user_ok;
    char username[32];
    uint32_t data_ip;
    uint16_t data_port;
    bool binary_mode;
} ftp_session_t;

/**
 * @brief Load password from NVS (shared with SSH)
 */
static void load_password(void)
{
    nvs_handle_t nvs;
    s_password[0] = '\0';
    s_password_required = false;

    esp_err_t ret = nvs_open(NVS_NAMESPACE, NVS_READONLY, &nvs);
    if (ret != ESP_OK) {
        ESP_LOGI(TAG, "No password configured - anonymous access enabled");
        return;
    }

    size_t len = sizeof(s_password);
    ret = nvs_get_str(nvs, NVS_KEY_PASSWORD, s_password, &len);
    nvs_close(nvs);

    if (ret == ESP_OK && strlen(s_password) > 0) {
        s_password_required = true;
        ESP_LOGI(TAG, "Password authentication enabled");
    } else {
        ESP_LOGI(TAG, "No password configured - anonymous access enabled");
    }
}

/**
 * @brief Send FTP response
 */
static void ftp_send(ftp_session_t *session, const char *fmt, ...)
{
    char buf[FTP_BUFFER_SIZE];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf) - 2, fmt, args);
    va_end(args);

    // Add CRLF
    buf[len++] = '\r';
    buf[len++] = '\n';
    buf[len] = '\0';

    send(session->ctrl_sock, buf, len, 0);
    ESP_LOGD(TAG, "TX: %.*s", len - 2, buf);
}

/**
 * @brief Get full path from relative path
 */
static void get_full_path(ftp_session_t *session, const char *arg, char *fullpath)
{
    if (arg[0] == '/') {
        snprintf(fullpath, FTP_FULL_PATH_SIZE, "%s%s", FTP_ROOT_DIR, arg);
    } else {
        if (strcmp(session->cwd, "/") == 0) {
            snprintf(fullpath, FTP_FULL_PATH_SIZE, "%s/%s", FTP_ROOT_DIR, arg);
        } else {
            snprintf(fullpath, FTP_FULL_PATH_SIZE, "%s%s/%s", FTP_ROOT_DIR, session->cwd, arg);
        }
    }
}

/**
 * @brief Open data connection (passive or active mode)
 */
static int open_data_connection(ftp_session_t *session)
{
    if (session->pasv_sock >= 0) {
        // Passive mode - accept connection
        struct sockaddr_in client_addr;
        socklen_t addr_len = sizeof(client_addr);
        int data_sock = accept(session->pasv_sock, (struct sockaddr *)&client_addr, &addr_len);
        close(session->pasv_sock);
        session->pasv_sock = -1;
        return data_sock;
    } else if (session->data_port > 0) {
        // Active mode - connect to client
        int sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock < 0) return -1;

        struct sockaddr_in addr = {
            .sin_family = AF_INET,
            .sin_port = htons(session->data_port),
            .sin_addr.s_addr = htonl(session->data_ip),
        };

        if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
            close(sock);
            return -1;
        }
        session->data_port = 0;
        return sock;
    }
    return -1;
}

/**
 * @brief Handle USER command
 */
static void cmd_user(ftp_session_t *session, const char *arg)
{
    strncpy(session->username, arg, sizeof(session->username) - 1);
    session->user_ok = true;

    if (!s_password_required) {
        session->logged_in = true;
        ftp_send(session, "230 User logged in");
    } else {
        ftp_send(session, "331 Password required");
    }
}

/**
 * @brief Handle PASS command
 */
static void cmd_pass(ftp_session_t *session, const char *arg)
{
    if (!session->user_ok) {
        ftp_send(session, "503 Login with USER first");
        return;
    }

    if (!s_password_required) {
        session->logged_in = true;
        ftp_send(session, "230 User logged in");
    } else if (strcmp(arg, s_password) == 0) {
        session->logged_in = true;
        ftp_send(session, "230 User logged in");
    } else {
        ftp_send(session, "530 Login incorrect");
    }
}

/**
 * @brief Handle SYST command
 */
static void cmd_syst(ftp_session_t *session)
{
    ftp_send(session, "215 UNIX Type: L8");
}

/**
 * @brief Handle FEAT command
 */
static void cmd_feat(ftp_session_t *session)
{
    ftp_send(session, "211-Features:");
    ftp_send(session, " PASV");
    ftp_send(session, " SIZE");
    ftp_send(session, " UTF8");
    ftp_send(session, "211 End");
}

/**
 * @brief Handle PWD command
 */
static void cmd_pwd(ftp_session_t *session)
{
    ftp_send(session, "257 \"%s\" is current directory", session->cwd);
}

/**
 * @brief Handle CWD command
 */
static void cmd_cwd(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    char newcwd[FTP_CWD_SIZE];

    if (strcmp(arg, "/") == 0) {
        strcpy(session->cwd, "/");
        ftp_send(session, "250 Directory changed to /");
        return;
    }

    if (strcmp(arg, "..") == 0) {
        // Go up one level
        char *last = strrchr(session->cwd, '/');
        if (last && last != session->cwd) {
            *last = '\0';
        } else {
            strcpy(session->cwd, "/");
        }
        ftp_send(session, "250 Directory changed to %s", session->cwd);
        return;
    }

    // Build new path
    if (arg[0] == '/') {
        snprintf(newcwd, sizeof(newcwd), "%s", arg);
    } else {
        if (strcmp(session->cwd, "/") == 0) {
            snprintf(newcwd, sizeof(newcwd), "/%s", arg);
        } else {
            snprintf(newcwd, sizeof(newcwd), "%s/%s", session->cwd, arg);
        }
    }

    // Check if directory exists
    snprintf(fullpath, sizeof(fullpath), "%s%s", FTP_ROOT_DIR, newcwd);
    struct stat st;
    if (stat(fullpath, &st) == 0 && S_ISDIR(st.st_mode)) {
        strcpy(session->cwd, newcwd);
        ftp_send(session, "250 Directory changed to %s", session->cwd);
    } else {
        ftp_send(session, "550 Directory not found");
    }
}

/**
 * @brief Handle TYPE command
 */
static void cmd_type(ftp_session_t *session, const char *arg)
{
    if (arg[0] == 'I' || arg[0] == 'i') {
        session->binary_mode = true;
        ftp_send(session, "200 Type set to I");
    } else if (arg[0] == 'A' || arg[0] == 'a') {
        session->binary_mode = false;
        ftp_send(session, "200 Type set to A");
    } else {
        ftp_send(session, "504 Type not supported");
    }
}

/**
 * @brief Handle PASV command
 */
static void cmd_pasv(ftp_session_t *session)
{
    // Close existing passive socket
    if (session->pasv_sock >= 0) {
        close(session->pasv_sock);
    }

    // Create passive socket
    session->pasv_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (session->pasv_sock < 0) {
        ftp_send(session, "425 Cannot open passive connection");
        return;
    }

    // Bind to random port
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = 0,
        .sin_addr.s_addr = INADDR_ANY,
    };

    if (bind(session->pasv_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(session->pasv_sock);
        session->pasv_sock = -1;
        ftp_send(session, "425 Cannot open passive connection");
        return;
    }

    listen(session->pasv_sock, 1);

    // Get local address and port
    socklen_t addr_len = sizeof(addr);
    getsockname(session->pasv_sock, (struct sockaddr *)&addr, &addr_len);
    uint16_t port = ntohs(addr.sin_port);

    // Get local IP from control socket
    getsockname(session->ctrl_sock, (struct sockaddr *)&addr, &addr_len);
    uint8_t *ip = (uint8_t *)&addr.sin_addr.s_addr;

    ftp_send(session, "227 Entering Passive Mode (%d,%d,%d,%d,%d,%d)",
             ip[0], ip[1], ip[2], ip[3], port >> 8, port & 0xff);
}

/**
 * @brief Handle PORT command
 */
static void cmd_port(ftp_session_t *session, const char *arg)
{
    unsigned int h1, h2, h3, h4, p1, p2;
    if (sscanf(arg, "%u,%u,%u,%u,%u,%u", &h1, &h2, &h3, &h4, &p1, &p2) != 6) {
        ftp_send(session, "501 Invalid PORT command");
        return;
    }

    session->data_ip = (h1 << 24) | (h2 << 16) | (h3 << 8) | h4;
    session->data_port = (p1 << 8) | p2;

    ftp_send(session, "200 PORT command successful");
}

/**
 * @brief Handle LIST command
 */
static void cmd_list(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];

    if (arg && strlen(arg) > 0 && arg[0] != '-') {
        get_full_path(session, arg, fullpath);
    } else {
        snprintf(fullpath, sizeof(fullpath), "%s%s", FTP_ROOT_DIR, session->cwd);
    }

    DIR *dir = opendir(fullpath);
    if (!dir) {
        ftp_send(session, "550 Cannot open directory");
        return;
    }

    ftp_send(session, "150 Opening data connection");

    int data_sock = open_data_connection(session);
    if (data_sock < 0) {
        closedir(dir);
        ftp_send(session, "425 Cannot open data connection");
        return;
    }

    char buf[512];
    struct dirent *entry;
    struct stat st;

    while ((entry = readdir(dir)) != NULL) {
        char filepath[FTP_FILEPATH_SIZE];
        snprintf(filepath, sizeof(filepath), "%s/%s", fullpath, entry->d_name);

        if (stat(filepath, &st) == 0) {
            char perms[11] = "----------";
            if (S_ISDIR(st.st_mode)) perms[0] = 'd';
            perms[1] = 'r'; perms[2] = 'w';
            if (S_ISDIR(st.st_mode)) perms[3] = 'x';

            int len = snprintf(buf, sizeof(buf), "%s 1 root root %8ld Jan  1 00:00 %s\r\n",
                              perms, (long)st.st_size, entry->d_name);
            send(data_sock, buf, len, 0);
        }
    }

    closedir(dir);
    close(data_sock);
    ftp_send(session, "226 Transfer complete");
}

/**
 * @brief Handle RETR command (download)
 */
static void cmd_retr(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    FILE *f = fopen(fullpath, "rb");
    if (!f) {
        ftp_send(session, "550 File not found");
        return;
    }

    ftp_send(session, "150 Opening data connection");

    int data_sock = open_data_connection(session);
    if (data_sock < 0) {
        fclose(f);
        ftp_send(session, "425 Cannot open data connection");
        return;
    }

    char *buf = malloc(FTP_DATA_BUFFER_SIZE);
    if (!buf) {
        fclose(f);
        close(data_sock);
        ftp_send(session, "451 Local error");
        return;
    }

    size_t n;
    while ((n = fread(buf, 1, FTP_DATA_BUFFER_SIZE, f)) > 0) {
        send(data_sock, buf, n, 0);
    }

    free(buf);
    fclose(f);
    close(data_sock);
    ftp_send(session, "226 Transfer complete");
}

/**
 * @brief Handle STOR command (upload)
 */
static void cmd_stor(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    FILE *f = fopen(fullpath, "wb");
    if (!f) {
        ftp_send(session, "550 Cannot create file");
        return;
    }

    ftp_send(session, "150 Opening data connection");

    int data_sock = open_data_connection(session);
    if (data_sock < 0) {
        fclose(f);
        ftp_send(session, "425 Cannot open data connection");
        return;
    }

    char *buf = malloc(FTP_DATA_BUFFER_SIZE);
    if (!buf) {
        fclose(f);
        close(data_sock);
        ftp_send(session, "451 Local error");
        return;
    }

    ssize_t n;
    while ((n = recv(data_sock, buf, FTP_DATA_BUFFER_SIZE, 0)) > 0) {
        fwrite(buf, 1, n, f);
    }

    free(buf);
    fclose(f);
    close(data_sock);
    ftp_send(session, "226 Transfer complete");
}

/**
 * @brief Handle DELE command
 */
static void cmd_dele(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    if (unlink(fullpath) == 0) {
        ftp_send(session, "250 File deleted");
    } else {
        ftp_send(session, "550 Delete failed");
    }
}

/**
 * @brief Handle MKD command
 */
static void cmd_mkd(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    if (mkdir(fullpath, 0755) == 0) {
        ftp_send(session, "257 \"%s\" created", arg);
    } else {
        ftp_send(session, "550 Cannot create directory");
    }
}

/**
 * @brief Handle RMD command
 */
static void cmd_rmd(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    if (rmdir(fullpath) == 0) {
        ftp_send(session, "250 Directory removed");
    } else {
        ftp_send(session, "550 Cannot remove directory");
    }
}

/**
 * @brief Handle SIZE command
 */
static void cmd_size(ftp_session_t *session, const char *arg)
{
    char fullpath[FTP_FULL_PATH_SIZE];
    get_full_path(session, arg, fullpath);

    struct stat st;
    if (stat(fullpath, &st) == 0 && S_ISREG(st.st_mode)) {
        ftp_send(session, "213 %ld", (long)st.st_size);
    } else {
        ftp_send(session, "550 File not found");
    }
}

/**
 * @brief Handle NOOP command
 */
static void cmd_noop(ftp_session_t *session)
{
    ftp_send(session, "200 NOOP ok");
}

/**
 * @brief Handle QUIT command
 */
static void cmd_quit(ftp_session_t *session)
{
    ftp_send(session, "221 Goodbye");
}

/**
 * @brief Process FTP command
 */
static bool process_command(ftp_session_t *session, char *line)
{
    // Parse command and argument
    char *cmd = line;
    char *arg = strchr(line, ' ');
    if (arg) {
        *arg++ = '\0';
        while (*arg == ' ') arg++;
    } else {
        arg = "";
    }

    // Convert command to uppercase
    for (char *p = cmd; *p; p++) {
        if (*p >= 'a' && *p <= 'z') *p -= 32;
    }

    ESP_LOGD(TAG, "RX: %s %s", cmd, arg);

    // Commands allowed before login
    if (strcmp(cmd, "USER") == 0) { cmd_user(session, arg); return true; }
    if (strcmp(cmd, "PASS") == 0) { cmd_pass(session, arg); return true; }
    if (strcmp(cmd, "QUIT") == 0) { cmd_quit(session); return false; }

    // Check login
    if (!session->logged_in) {
        ftp_send(session, "530 Please login first");
        return true;
    }

    // Commands requiring login
    if (strcmp(cmd, "SYST") == 0) { cmd_syst(session); }
    else if (strcmp(cmd, "FEAT") == 0) { cmd_feat(session); }
    else if (strcmp(cmd, "PWD") == 0 || strcmp(cmd, "XPWD") == 0) { cmd_pwd(session); }
    else if (strcmp(cmd, "CWD") == 0 || strcmp(cmd, "XCWD") == 0) { cmd_cwd(session, arg); }
    else if (strcmp(cmd, "CDUP") == 0 || strcmp(cmd, "XCUP") == 0) { cmd_cwd(session, ".."); }
    else if (strcmp(cmd, "TYPE") == 0) { cmd_type(session, arg); }
    else if (strcmp(cmd, "PASV") == 0) { cmd_pasv(session); }
    else if (strcmp(cmd, "PORT") == 0) { cmd_port(session, arg); }
    else if (strcmp(cmd, "LIST") == 0) { cmd_list(session, arg); }
    else if (strcmp(cmd, "NLST") == 0) { cmd_list(session, arg); }
    else if (strcmp(cmd, "RETR") == 0) { cmd_retr(session, arg); }
    else if (strcmp(cmd, "STOR") == 0) { cmd_stor(session, arg); }
    else if (strcmp(cmd, "DELE") == 0) { cmd_dele(session, arg); }
    else if (strcmp(cmd, "MKD") == 0 || strcmp(cmd, "XMKD") == 0) { cmd_mkd(session, arg); }
    else if (strcmp(cmd, "RMD") == 0 || strcmp(cmd, "XRMD") == 0) { cmd_rmd(session, arg); }
    else if (strcmp(cmd, "SIZE") == 0) { cmd_size(session, arg); }
    else if (strcmp(cmd, "NOOP") == 0) { cmd_noop(session); }
    else {
        ftp_send(session, "502 Command not implemented");
    }

    return true;
}

/**
 * @brief Handle FTP client session
 */
static void handle_client(int client_sock, struct sockaddr_in *client_addr)
{
    inet_ntop(AF_INET, &client_addr->sin_addr, s_client_ip, sizeof(s_client_ip));
    ESP_LOGI(TAG, "Client connected from %s", s_client_ip);

    ftp_session_t session = {
        .ctrl_sock = client_sock,
        .data_sock = -1,
        .pasv_sock = -1,
        .logged_in = false,
        .user_ok = false,
        .binary_mode = true,
        .data_port = 0,
    };
    strcpy(session.cwd, "/");

    // Send welcome
    ftp_send(&session, "220 Geogram FTP Server Ready");

    char buf[FTP_BUFFER_SIZE];
    int buf_pos = 0;

    while (s_running) {
        ssize_t n = recv(client_sock, buf + buf_pos, sizeof(buf) - buf_pos - 1, 0);
        if (n <= 0) break;

        buf_pos += n;
        buf[buf_pos] = '\0';

        // Process complete lines
        char *line_start = buf;
        char *line_end;
        while ((line_end = strstr(line_start, "\r\n")) != NULL) {
            *line_end = '\0';

            if (!process_command(&session, line_start)) {
                goto cleanup;
            }

            line_start = line_end + 2;
        }

        // Move remaining data to beginning
        if (line_start != buf) {
            buf_pos = strlen(line_start);
            memmove(buf, line_start, buf_pos + 1);
        }
    }

cleanup:
    if (session.pasv_sock >= 0) close(session.pasv_sock);
    if (session.data_sock >= 0) close(session.data_sock);
    close(client_sock);
    s_client_sock = -1;
    s_client_ip[0] = '\0';
    ESP_LOGI(TAG, "Client disconnected");
}

/**
 * @brief FTP server task
 */
static void ftp_server_task(void *arg)
{
    struct sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);

    while (s_running) {
        s_client_sock = accept(s_listen_sock, (struct sockaddr *)&client_addr, &addr_len);
        if (s_client_sock < 0) {
            if (s_running) {
                ESP_LOGE(TAG, "Accept failed: %d", errno);
                vTaskDelay(pdMS_TO_TICKS(1000));
            }
            continue;
        }

        handle_client(s_client_sock, &client_addr);
    }

    s_server_task = NULL;
    vTaskDelete(NULL);
}

esp_err_t ftp_server_start(uint16_t port)
{
    if (s_running) {
        ESP_LOGW(TAG, "FTP server already running");
        return ESP_OK;
    }

    if (!sdcard_is_mounted()) {
        ESP_LOGE(TAG, "SD card not mounted");
        return ESP_ERR_INVALID_STATE;
    }

    // Load password configuration
    load_password();

    // Create socket
    s_listen_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (s_listen_sock < 0) {
        ESP_LOGE(TAG, "Failed to create socket");
        return ESP_FAIL;
    }

    int opt = 1;
    setsockopt(s_listen_sock, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port = htons(port),
        .sin_addr.s_addr = INADDR_ANY,
    };

    if (bind(s_listen_sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        ESP_LOGE(TAG, "Failed to bind socket");
        close(s_listen_sock);
        s_listen_sock = -1;
        return ESP_FAIL;
    }

    if (listen(s_listen_sock, 1) < 0) {
        ESP_LOGE(TAG, "Failed to listen");
        close(s_listen_sock);
        s_listen_sock = -1;
        return ESP_FAIL;
    }

    s_port = port;
    s_running = true;

    if (xTaskCreate(ftp_server_task, "ftp_server", FTP_TASK_STACK_SIZE,
                    NULL, FTP_TASK_PRIORITY, &s_server_task) != pdPASS) {
        ESP_LOGE(TAG, "Failed to create task");
        close(s_listen_sock);
        s_listen_sock = -1;
        s_running = false;
        return ESP_FAIL;
    }

    ESP_LOGI(TAG, "FTP server started on port %d (auth: %s)",
             port, s_password_required ? "password" : "anonymous");
    return ESP_OK;
}

void ftp_server_stop(void)
{
    if (!s_running) return;

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
    while (s_server_task != NULL) {
        vTaskDelay(pdMS_TO_TICKS(100));
    }

    s_port = 0;
    ESP_LOGI(TAG, "FTP server stopped");
}

bool ftp_server_is_running(void)
{
    return s_running;
}

uint16_t ftp_server_get_port(void)
{
    return s_port;
}

bool ftp_server_is_client_connected(void)
{
    return s_client_sock >= 0;
}

esp_err_t ftp_server_get_client_ip(char *ip_str)
{
    if (s_client_sock < 0 || s_client_ip[0] == '\0') {
        return ESP_ERR_NOT_FOUND;
    }
    strcpy(ip_str, s_client_ip);
    return ESP_OK;
}
