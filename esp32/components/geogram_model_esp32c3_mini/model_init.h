#ifndef MODEL_INIT_H
#define MODEL_INIT_H

#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initialize board hardware
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t model_init(void);

/**
 * @brief Deinitialize board hardware
 *
 * @return esp_err_t ESP_OK on success
 */
esp_err_t model_deinit(void);

#ifdef __cplusplus
}
#endif

#endif // MODEL_INIT_H
