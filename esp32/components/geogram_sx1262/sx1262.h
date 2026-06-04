#ifndef SX1262_H
#define SX1262_H

#include <stdint.h>
#include <stdbool.h>
#include "esp_err.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief SX1262 spreading factor
 */
typedef enum {
    SX1262_SF5  = 5,
    SX1262_SF6  = 6,
    SX1262_SF7  = 7,
    SX1262_SF8  = 8,
    SX1262_SF9  = 9,
    SX1262_SF10 = 10,
    SX1262_SF11 = 11,
    SX1262_SF12 = 12,
} sx1262_sf_t;

/**
 * @brief SX1262 bandwidth
 */
typedef enum {
    SX1262_BW_7_8   = 0x00,
    SX1262_BW_10_4  = 0x08,
    SX1262_BW_15_6  = 0x01,
    SX1262_BW_20_8  = 0x09,
    SX1262_BW_31_25 = 0x02,
    SX1262_BW_41_7  = 0x0A,
    SX1262_BW_62_5  = 0x03,
    SX1262_BW_125   = 0x04,
    SX1262_BW_250   = 0x05,
    SX1262_BW_500   = 0x06,
} sx1262_bw_t;

/**
 * @brief SX1262 coding rate
 */
typedef enum {
    SX1262_CR_4_5 = 0x01,
    SX1262_CR_4_6 = 0x02,
    SX1262_CR_4_7 = 0x03,
    SX1262_CR_4_8 = 0x04,
} sx1262_cr_t;

/**
 * @brief SX1262 SPI pin configuration
 */
typedef struct {
    int mosi_pin;
    int miso_pin;
    int sck_pin;
    int cs_pin;
    int rst_pin;
    int busy_pin;
    int dio1_pin;       // DIO1 interrupt pin (-1 if not used)
} sx1262_spi_config_t;

/**
 * @brief SX1262 LoRa configuration
 */
typedef struct {
    uint32_t frequency_hz;  // Center frequency in Hz (e.g., 868000000)
    sx1262_sf_t sf;         // Spreading factor
    sx1262_bw_t bw;         // Bandwidth
    sx1262_cr_t cr;         // Coding rate
    int8_t tx_power_dbm;    // TX power in dBm (max 22)
    uint16_t preamble_len;  // Preamble length in symbols
    bool crc_on;            // Enable CRC
    bool use_tcxo;          // Enable TCXO via DIO3 (Heltec V3 requires this)
    bool use_dio2_rf_switch;// Use DIO2 as RF switch (Heltec V3 requires this)
} sx1262_lora_config_t;

/**
 * @brief Received packet info
 */
typedef struct {
    int16_t rssi;           // RSSI in dBm
    int8_t snr;             // SNR in dB
    uint8_t len;            // Payload length
} sx1262_rx_info_t;

/**
 * @brief RX callback function type
 */
typedef void (*sx1262_rx_callback_t)(void *user_data);

/**
 * @brief SX1262 handle (opaque type)
 */
typedef struct sx1262_dev *sx1262_handle_t;

/**
 * @brief Create an SX1262 instance
 *
 * @param spi_config SPI pin configuration
 * @param handle Pointer to store the handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_create(const sx1262_spi_config_t *spi_config, sx1262_handle_t *handle);

/**
 * @brief Initialize the SX1262 with LoRa configuration
 *
 * @param handle SX1262 handle
 * @param config LoRa configuration
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_init(sx1262_handle_t handle, const sx1262_lora_config_t *config);

/**
 * @brief Delete the SX1262 instance
 *
 * @param handle SX1262 handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_delete(sx1262_handle_t handle);

/**
 * @brief Send a LoRa packet
 *
 * @param handle SX1262 handle
 * @param data Packet data
 * @param len Packet length (max 255)
 * @param timeout_ms Timeout in milliseconds
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_send(sx1262_handle_t handle, const uint8_t *data, uint8_t len,
                       uint32_t timeout_ms);

/**
 * @brief Start continuous receive mode
 *
 * @param handle SX1262 handle
 * @param callback Function called when packet received (from ISR context)
 * @param user_data User data passed to callback
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_start_receive(sx1262_handle_t handle, sx1262_rx_callback_t callback,
                                void *user_data);

/**
 * @brief Get received packet data
 *
 * @param handle SX1262 handle
 * @param buf Buffer to store received data
 * @param buf_len Buffer size
 * @param info Pointer to store packet info (RSSI, SNR, length)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_get_packet(sx1262_handle_t handle, uint8_t *buf, uint8_t buf_len,
                             sx1262_rx_info_t *info);

/**
 * @brief Set radio to standby mode
 *
 * @param handle SX1262 handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_standby(sx1262_handle_t handle);

/**
 * @brief Set radio to sleep mode
 *
 * @param handle SX1262 handle
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_sleep(sx1262_handle_t handle);

/**
 * @brief Set frequency
 *
 * @param handle SX1262 handle
 * @param freq_hz Frequency in Hz
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_set_frequency(sx1262_handle_t handle, uint32_t freq_hz);

/**
 * @brief Set TX power
 *
 * @param handle SX1262 handle
 * @param power_dbm Power in dBm (max 22)
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_set_tx_power(sx1262_handle_t handle, int8_t power_dbm);

/**
 * @brief Set spreading factor
 *
 * @param handle SX1262 handle
 * @param sf Spreading factor
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_set_sf(sx1262_handle_t handle, sx1262_sf_t sf);

/**
 * @brief Set bandwidth
 *
 * @param handle SX1262 handle
 * @param bw Bandwidth
 * @return esp_err_t ESP_OK on success
 */
esp_err_t sx1262_set_bw(sx1262_handle_t handle, sx1262_bw_t bw);

#ifdef __cplusplus
}
#endif

#endif // SX1262_H
