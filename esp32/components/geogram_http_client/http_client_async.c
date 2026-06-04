/**
 * @file http_client_async.c
 * @brief Async HTTP client implementation
 */

#include <string.h>
#include "http_client_async.h"
#include "esp_http_client.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static const char *TAG = "http_async";

// Task stack size - must be large enough for TLS (mbedTLS needs ~10KB)
#define HTTP_TASK_STACK_SIZE    (12 * 1024)

// Default timeout
#define DEFAULT_TIMEOUT_MS      15000

// Default user agent
#define DEFAULT_USER_AGENT      "ESP32-HTTP/1.0"

/**
 * @brief Internal request context passed to task
 */
typedef struct {
    http_client_request_t request;
    http_client_response_t *response;
    esp_err_t result;
    SemaphoreHandle_t done_sem;
} http_task_ctx_t;

/**
 * @brief Perform the actual HTTP request (runs in dedicated task)
 */
static void http_request_task(void *arg)
{
    http_task_ctx_t *ctx = (http_task_ctx_t *)arg;
    http_client_response_t *resp = ctx->response;

    // Initialize response
    resp->status_code = 0;
    resp->data_len = 0;

    // Configure HTTP client - use insecure mode for tile downloads
    // Certificate verification is skipped as tiles are not sensitive data
    esp_http_client_config_t config = {
        .url = ctx->request.url,
        .timeout_ms = ctx->request.timeout_ms > 0 ? ctx->request.timeout_ms : DEFAULT_TIMEOUT_MS,
        .user_agent = ctx->request.user_agent ? ctx->request.user_agent : DEFAULT_USER_AGENT,
        .cert_pem = NULL,
        .skip_cert_common_name_check = true,
        .use_global_ca_store = false,
    };

    ESP_LOGI(TAG, "HTTP GET: %s", config.url);

    esp_http_client_handle_t client = esp_http_client_init(&config);
    if (client == NULL) {
        ESP_LOGE(TAG, "Failed to init HTTP client");
        ctx->result = ESP_FAIL;
        goto done;
    }

    ESP_LOGI(TAG, "Opening HTTP connection...");
    esp_err_t err = esp_http_client_open(client, 0);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "Failed to open HTTP connection: %s", esp_err_to_name(err));
        esp_http_client_cleanup(client);
        ctx->result = err;
        goto done;
    }
    ESP_LOGI(TAG, "HTTP connection opened");

    int content_length = esp_http_client_fetch_headers(client);
    resp->status_code = esp_http_client_get_status_code(client);

    ESP_LOGD(TAG, "HTTP status: %d, content-length: %d", resp->status_code, content_length);

    if (resp->status_code != 200) {
        ESP_LOGW(TAG, "HTTP error %d for %s", resp->status_code, config.url);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        ctx->result = ESP_FAIL;
        goto done;
    }

    // Check if response fits in buffer
    if (content_length > 0 && (size_t)content_length > resp->buffer_size) {
        ESP_LOGE(TAG, "Response too large: %d bytes (buffer: %zu)", content_length, resp->buffer_size);
        esp_http_client_close(client);
        esp_http_client_cleanup(client);
        ctx->result = ESP_ERR_NO_MEM;
        goto done;
    }

    // Read response
    int read_len = esp_http_client_read(client, (char *)resp->data, resp->buffer_size);
    esp_http_client_close(client);
    esp_http_client_cleanup(client);

    if (read_len < 0) {
        ESP_LOGE(TAG, "Failed to read HTTP response");
        ctx->result = ESP_FAIL;
        goto done;
    }

    resp->data_len = (size_t)read_len;
    ESP_LOGD(TAG, "HTTP GET complete: %zu bytes", resp->data_len);
    ctx->result = ESP_OK;

done:
    // Signal completion
    xSemaphoreGive(ctx->done_sem);
    vTaskDelete(NULL);
}

http_client_request_t http_client_default_config(void)
{
    http_client_request_t config = {
        .url = NULL,
        .user_agent = DEFAULT_USER_AGENT,
        .timeout_ms = DEFAULT_TIMEOUT_MS,
        .skip_cert_verify = true,
    };
    return config;
}

esp_err_t http_client_get_async(const http_client_request_t *request, http_client_response_t *response)
{
    if (request == NULL || request->url == NULL || response == NULL) {
        return ESP_ERR_INVALID_ARG;
    }

    if (response->data == NULL || response->buffer_size == 0) {
        return ESP_ERR_INVALID_ARG;
    }

    // Create task context
    http_task_ctx_t ctx = {
        .request = *request,
        .response = response,
        .result = ESP_FAIL,
        .done_sem = xSemaphoreCreateBinary()
    };

    if (ctx.done_sem == NULL) {
        ESP_LOGE(TAG, "Failed to create semaphore");
        return ESP_ERR_NO_MEM;
    }

    // Spawn task with adequate stack for TLS
    BaseType_t ret = xTaskCreate(http_request_task, "http_req", HTTP_TASK_STACK_SIZE,
                                  &ctx, 5, NULL);
    if (ret != pdPASS) {
        ESP_LOGE(TAG, "Failed to create HTTP task");
        vSemaphoreDelete(ctx.done_sem);
        return ESP_ERR_NO_MEM;
    }

    // Calculate wait timeout
    int timeout_ms = request->timeout_ms > 0 ? request->timeout_ms : DEFAULT_TIMEOUT_MS;
    timeout_ms += 5000;  // Extra margin for task overhead

    // Wait for completion
    if (xSemaphoreTake(ctx.done_sem, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        ESP_LOGE(TAG, "HTTP request timed out");
        vSemaphoreDelete(ctx.done_sem);
        return ESP_ERR_TIMEOUT;
    }

    vSemaphoreDelete(ctx.done_sem);
    return ctx.result;
}
