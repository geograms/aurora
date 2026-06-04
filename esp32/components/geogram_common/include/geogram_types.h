#ifndef GEOGRAM_TYPES_H
#define GEOGRAM_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

// Board model definitions
#define MODEL_ESP32S3_EPAPER_1IN54  1
#define MODEL_ESP32_GENERIC         99

// Geogram error codes
typedef enum {
    GEOGRAM_OK = 0,
    GEOGRAM_ERR_INVALID_ARG = -1,
    GEOGRAM_ERR_NO_MEM = -2,
    GEOGRAM_ERR_NOT_FOUND = -3,
    GEOGRAM_ERR_NOT_SUPPORTED = -4,
    GEOGRAM_ERR_TIMEOUT = -5,
    GEOGRAM_ERR_INVALID_STATE = -6,
    GEOGRAM_ERR_IO = -7,
} geogram_err_t;

// Common result type
typedef struct {
    esp_err_t err;
    const char *message;
} geogram_result_t;

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_TYPES_H
