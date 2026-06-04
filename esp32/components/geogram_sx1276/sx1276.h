#ifndef SX1276_H
#define SX1276_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief SX1276 spreading factor
 */
typedef enum {
    SX1276_SF6  = 6,
    SX1276_SF7  = 7,
    SX1276_SF8  = 8,
    SX1276_SF9  = 9,
    SX1276_SF10 = 10,
    SX1276_SF11 = 11,
    SX1276_SF12 = 12,
} sx1276_sf_t;

/**
 * @brief SX1276 bandwidth
 */
typedef enum {
    SX1276_BW_7_8   = 0,
    SX1276_BW_10_4  = 1,
    SX1276_BW_15_6  = 2,
    SX1276_BW_20_8  = 3,
    SX1276_BW_31_25 = 4,
    SX1276_BW_41_7  = 5,
    SX1276_BW_62_5  = 6,
    SX1276_BW_125   = 7,
    SX1276_BW_250   = 8,
    SX1276_BW_500   = 9,
} sx1276_bw_t;

/**
 * @brief SX1276 coding rate
 */
typedef enum {
    SX1276_CR_4_5 = 1,
    SX1276_CR_4_6 = 2,
    SX1276_CR_4_7 = 3,
    SX1276_CR_4_8 = 4,
} sx1276_cr_t;

/**
 * @brief SX1276 SPI pin configuration
 */
typedef struct {
    int mosi_pin;
    int miso_pin;
    int sck_pin;
    int cs_pin;
    int rst_pin;
    int dio0_pin;       // DIO0 interrupt pin (TX_DONE / RX_DONE)
} sx1276_spi_config_t;

/**
 * @brief SX1276 LoRa configuration
 */
typedef struct {
    uint32_t frequency_hz;  // Center frequency in Hz (e.g., 868000000)
    sx1276_sf_t sf;         // Spreading factor
    sx1276_bw_t bw;         // Bandwidth
    sx1276_cr_t cr;         // Coding rate
    int8_t tx_power_dbm;    // TX power in dBm (max 20 with PA_BOOST)
    uint16_t preamble_len;  // Preamble length in symbols
    bool crc_on;            // Enable CRC
} sx1276_lora_config_t;

/**
 * @brief Received packet info
 */
typedef struct {
    int16_t rssi;           // RSSI in dBm
    int8_t snr;             // SNR in dB
    uint8_t len;            // Payload length
} sx1276_rx_info_t;

/**
 * @brief RX callback function type
 */
typedef void (*sx1276_rx_callback_t)(void *user_data);

/**
 * @brief SX1276 handle (opaque type)
 */
typedef struct sx1276_dev *sx1276_handle_t;

/**
 * @brief Create an SX1276 instance
 */
esp_err_t sx1276_create(const sx1276_spi_config_t *spi_config, sx1276_handle_t *handle);

/**
 * @brief Initialize the SX1276 with LoRa configuration
 */
esp_err_t sx1276_init(sx1276_handle_t handle, const sx1276_lora_config_t *config);

/**
 * @brief Delete the SX1276 instance
 */
esp_err_t sx1276_delete(sx1276_handle_t handle);

/**
 * @brief Send a LoRa packet
 */
esp_err_t sx1276_send(sx1276_handle_t handle, const uint8_t *data, uint8_t len,
                       uint32_t timeout_ms);

/**
 * @brief Start continuous receive mode
 */
esp_err_t sx1276_start_receive(sx1276_handle_t handle, sx1276_rx_callback_t callback,
                                void *user_data);

/**
 * @brief Get received packet data
 */
esp_err_t sx1276_get_packet(sx1276_handle_t handle, uint8_t *buf, uint8_t buf_len,
                             sx1276_rx_info_t *info);

/**
 * @brief Set radio to standby mode
 */
esp_err_t sx1276_standby(sx1276_handle_t handle);

/**
 * @brief Set radio to sleep mode
 */
esp_err_t sx1276_sleep(sx1276_handle_t handle);

/**
 * @brief Set frequency
 */
esp_err_t sx1276_set_frequency(sx1276_handle_t handle, uint32_t freq_hz);

/**
 * @brief Set TX power
 */
esp_err_t sx1276_set_tx_power(sx1276_handle_t handle, int8_t power_dbm);

/**
 * @brief Set spreading factor
 */
esp_err_t sx1276_set_sf(sx1276_handle_t handle, sx1276_sf_t sf);

/**
 * @brief Set bandwidth
 */
esp_err_t sx1276_set_bw(sx1276_handle_t handle, sx1276_bw_t bw);

#ifdef __cplusplus
}
#endif

#endif // SX1276_H
