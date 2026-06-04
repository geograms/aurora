#include <string.h>
#include <stdlib.h>
#include "sx1276.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static const char *TAG = "sx1276";

// ============================================================================
// SX1276 register addresses
// ============================================================================
#define REG_FIFO                    0x00
#define REG_OP_MODE                 0x01
#define REG_FR_MSB                  0x06
#define REG_FR_MID                  0x07
#define REG_FR_LSB                  0x08
#define REG_PA_CONFIG               0x09
#define REG_PA_RAMP                 0x0A
#define REG_OCP                     0x0B
#define REG_LNA                     0x0C
#define REG_FIFO_ADDR_PTR          0x0D
#define REG_FIFO_TX_BASE_ADDR     0x0E
#define REG_FIFO_RX_BASE_ADDR     0x0F
#define REG_FIFO_RX_CURRENT_ADDR  0x10
#define REG_IRQ_FLAGS_MASK         0x11
#define REG_IRQ_FLAGS              0x12
#define REG_RX_NB_BYTES            0x13
#define REG_PKT_SNR_VALUE          0x1A
#define REG_PKT_RSSI_VALUE         0x1B
#define REG_MODEM_CONFIG_1         0x1D
#define REG_MODEM_CONFIG_2         0x1E
#define REG_SYMB_TIMEOUT_LSB       0x1F
#define REG_PREAMBLE_MSB           0x20
#define REG_PREAMBLE_LSB           0x21
#define REG_PAYLOAD_LENGTH         0x22
#define REG_MAX_PAYLOAD_LENGTH     0x23
#define REG_MODEM_CONFIG_3         0x26
#define REG_DETECT_OPTIMIZE        0x31
#define REG_DETECTION_THRESHOLD    0x37
#define REG_DIO_MAPPING_1          0x40
#define REG_DIO_MAPPING_2          0x41
#define REG_VERSION                0x42
#define REG_PA_DAC                 0x4D

// OpMode bits
#define OPMODE_LONG_RANGE          0x80    // LoRa mode
#define OPMODE_SLEEP               0x00
#define OPMODE_STANDBY             0x01
#define OPMODE_TX                  0x03
#define OPMODE_RX_CONTINUOUS       0x05
#define OPMODE_RX_SINGLE           0x06

// IRQ flags
#define IRQ_RX_TIMEOUT             0x80
#define IRQ_RX_DONE                0x40
#define IRQ_PAYLOAD_CRC_ERROR      0x20
#define IRQ_VALID_HEADER           0x10
#define IRQ_TX_DONE                0x08
#define IRQ_CAD_DONE               0x04
#define IRQ_FHSS_CHANGE_CHANNEL   0x02
#define IRQ_CAD_DETECTED           0x01

// PA config
#define PA_BOOST                   0x80

// PA DAC
#define PA_DAC_ENABLE              0x87    // +20dBm on PA_BOOST
#define PA_DAC_DISABLE             0x84    // Default

// DIO0 mapping (bits 7:6 of RegDioMapping1)
#define DIO0_RX_DONE               0x00    // 00 = RxDone
#define DIO0_TX_DONE               0x40    // 01 = TxDone

// SPI clock speed
#define SX1276_SPI_CLOCK_HZ       (8 * 1000 * 1000)

// Mode transition delay (ms)
#define MODE_SWITCH_DELAY_MS       2

struct sx1276_dev {
    sx1276_spi_config_t spi_config;
    sx1276_lora_config_t lora_config;
    spi_device_handle_t spi;
    sx1276_rx_callback_t rx_callback;
    void *rx_user_data;
    SemaphoreHandle_t tx_done_sem;
    bool initialized;
};

// ============================================================================
// SPI helpers
// ============================================================================

static void sx1276_cs_low(sx1276_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.cs_pin, 0);
}

static void sx1276_cs_high(sx1276_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.cs_pin, 1);
}

static uint8_t sx1276_read_reg(sx1276_handle_t handle, uint8_t addr)
{
    uint8_t tx[2] = { addr & 0x7F, 0x00 };
    uint8_t rx[2] = { 0 };

    spi_transaction_t t = {};
    t.length = 16;
    t.tx_buffer = tx;
    t.rx_buffer = rx;

    sx1276_cs_low(handle);
    spi_device_polling_transmit(handle->spi, &t);
    sx1276_cs_high(handle);

    return rx[1];
}

static void sx1276_write_reg(sx1276_handle_t handle, uint8_t addr, uint8_t val)
{
    uint8_t tx[2] = { addr | 0x80, val };

    spi_transaction_t t = {};
    t.length = 16;
    t.tx_buffer = tx;

    sx1276_cs_low(handle);
    spi_device_polling_transmit(handle->spi, &t);
    sx1276_cs_high(handle);
}

static void sx1276_write_fifo(sx1276_handle_t handle, const uint8_t *data, uint8_t len)
{
    uint8_t addr = REG_FIFO | 0x80;

    sx1276_cs_low(handle);

    spi_transaction_t t1 = {};
    t1.length = 8;
    t1.tx_buffer = &addr;
    spi_device_polling_transmit(handle->spi, &t1);

    spi_transaction_t t2 = {};
    t2.length = len * 8;
    t2.tx_buffer = data;
    spi_device_polling_transmit(handle->spi, &t2);

    sx1276_cs_high(handle);
}

static void sx1276_read_fifo(sx1276_handle_t handle, uint8_t *buf, uint8_t len)
{
    uint8_t addr = REG_FIFO & 0x7F;

    sx1276_cs_low(handle);

    spi_transaction_t t1 = {};
    t1.length = 8;
    t1.tx_buffer = &addr;
    spi_device_polling_transmit(handle->spi, &t1);

    uint8_t dummy_tx[256] = {0};
    spi_transaction_t t2 = {};
    t2.length = len * 8;
    t2.tx_buffer = dummy_tx;
    t2.rx_buffer = buf;
    spi_device_polling_transmit(handle->spi, &t2);

    sx1276_cs_high(handle);
}

// ============================================================================
// Mode helpers
// ============================================================================

static void sx1276_set_mode(sx1276_handle_t handle, uint8_t mode)
{
    sx1276_write_reg(handle, REG_OP_MODE, OPMODE_LONG_RANGE | mode);
    vTaskDelay(pdMS_TO_TICKS(MODE_SWITCH_DELAY_MS));
}

// ============================================================================
// DIO0 ISR handler
// ============================================================================

static void IRAM_ATTR sx1276_dio0_isr(void *arg)
{
    sx1276_handle_t handle = (sx1276_handle_t)arg;
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;

    if (handle->tx_done_sem) {
        xSemaphoreGiveFromISR(handle->tx_done_sem, &xHigherPriorityTaskWoken);
    }

    if (handle->rx_callback) {
        handle->rx_callback(handle->rx_user_data);
    }

    if (xHigherPriorityTaskWoken) {
        portYIELD_FROM_ISR();
    }
}

// ============================================================================
// Hardware reset
// ============================================================================

static void sx1276_hw_reset(sx1276_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 0);
    vTaskDelay(pdMS_TO_TICKS(10));
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(10));
}

// ============================================================================
// Internal configuration helpers
// ============================================================================

static void sx1276_set_frequency_regs(sx1276_handle_t handle, uint32_t freq_hz)
{
    // Frf = freq_hz * 2^19 / 32MHz
    uint64_t frf = ((uint64_t)freq_hz << 19) / 32000000ULL;

    sx1276_write_reg(handle, REG_FR_MSB, (uint8_t)(frf >> 16));
    sx1276_write_reg(handle, REG_FR_MID, (uint8_t)(frf >> 8));
    sx1276_write_reg(handle, REG_FR_LSB, (uint8_t)(frf));
}

static void sx1276_set_pa_config(sx1276_handle_t handle, int8_t power_dbm)
{
    // Using PA_BOOST pin (required for Heltec V2)
    if (power_dbm > 20) power_dbm = 20;
    if (power_dbm < 2) power_dbm = 2;

    if (power_dbm > 17) {
        // Enable +20dBm mode via PA_DAC
        sx1276_write_reg(handle, REG_PA_DAC, PA_DAC_ENABLE);
        // OCP to 240mA for high power
        sx1276_write_reg(handle, REG_OCP, 0x3F);
        // OutputPower = power_dbm - 5
        sx1276_write_reg(handle, REG_PA_CONFIG, PA_BOOST | (power_dbm - 5));
    } else {
        sx1276_write_reg(handle, REG_PA_DAC, PA_DAC_DISABLE);
        // OCP to 100mA
        sx1276_write_reg(handle, REG_OCP, 0x2B);
        // OutputPower = power_dbm - 2
        sx1276_write_reg(handle, REG_PA_CONFIG, PA_BOOST | (power_dbm - 2));
    }
}

static void sx1276_set_modulation_config(sx1276_handle_t handle,
                                          sx1276_sf_t sf, sx1276_bw_t bw,
                                          sx1276_cr_t cr, bool crc_on)
{
    // RegModemConfig1: BW[7:4] | CR[3:1] | ImplicitHeader[0]
    uint8_t config1 = ((uint8_t)bw << 4) | ((uint8_t)cr << 1) | 0x00;  // Explicit header
    sx1276_write_reg(handle, REG_MODEM_CONFIG_1, config1);

    // RegModemConfig2: SF[7:4] | TxContinuousMode[3] | RxPayloadCrcOn[2] | SymbTimeout[1:0]
    uint8_t config2 = ((uint8_t)sf << 4) | (crc_on ? 0x04 : 0x00);
    sx1276_write_reg(handle, REG_MODEM_CONFIG_2, config2);

    // RegModemConfig3: LowDataRateOptimize[3] | AgcAutoOn[2]
    // Enable LDRO for SF11/SF12 at BW125 or lower
    bool ldro = (sf >= SX1276_SF11) && (bw <= SX1276_BW_125);
    uint8_t config3 = 0x04 | (ldro ? 0x08 : 0x00);  // AgcAutoOn=1
    sx1276_write_reg(handle, REG_MODEM_CONFIG_3, config3);

    // SF6 requires special detection settings
    if (sf == SX1276_SF6) {
        sx1276_write_reg(handle, REG_DETECT_OPTIMIZE, 0xC5);
        sx1276_write_reg(handle, REG_DETECTION_THRESHOLD, 0x0C);
    } else {
        sx1276_write_reg(handle, REG_DETECT_OPTIMIZE, 0xC3);
        sx1276_write_reg(handle, REG_DETECTION_THRESHOLD, 0x0A);
    }
}

// ============================================================================
// Public API
// ============================================================================

esp_err_t sx1276_create(const sx1276_spi_config_t *spi_config, sx1276_handle_t *handle)
{
    if (!spi_config || !handle) return ESP_ERR_INVALID_ARG;

    struct sx1276_dev *dev = calloc(1, sizeof(struct sx1276_dev));
    if (!dev) return ESP_ERR_NO_MEM;

    dev->spi_config = *spi_config;
    dev->tx_done_sem = xSemaphoreCreateBinary();
    if (!dev->tx_done_sem) {
        free(dev);
        return ESP_ERR_NO_MEM;
    }

    // Configure GPIO: CS, RST as outputs
    gpio_config_t out_conf = {
        .pin_bit_mask = (1ULL << spi_config->cs_pin) | (1ULL << spi_config->rst_pin),
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&out_conf);
    gpio_set_level((gpio_num_t)spi_config->cs_pin, 1);
    gpio_set_level((gpio_num_t)spi_config->rst_pin, 1);

    // DIO0 as input with rising edge interrupt
    if (spi_config->dio0_pin >= 0) {
        gpio_config_t dio0_conf = {
            .pin_bit_mask = (1ULL << spi_config->dio0_pin),
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_POSEDGE,
        };
        gpio_config(&dio0_conf);
        gpio_install_isr_service(0);
        gpio_isr_handler_add((gpio_num_t)spi_config->dio0_pin, sx1276_dio0_isr, dev);
    }

    // Initialize SPI bus
    spi_bus_config_t buscfg = {};
    buscfg.mosi_io_num = spi_config->mosi_pin;
    buscfg.miso_io_num = spi_config->miso_pin;
    buscfg.sclk_io_num = spi_config->sck_pin;
    buscfg.quadwp_io_num = -1;
    buscfg.quadhd_io_num = -1;
    buscfg.max_transfer_sz = 256 + 8;

    esp_err_t ret = spi_bus_initialize(SPI2_HOST, &buscfg, SPI_DMA_CH_AUTO);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SPI bus init failed: %s", esp_err_to_name(ret));
        vSemaphoreDelete(dev->tx_done_sem);
        free(dev);
        return ret;
    }

    spi_device_interface_config_t devcfg = {};
    devcfg.clock_speed_hz = SX1276_SPI_CLOCK_HZ;
    devcfg.mode = 0;
    devcfg.spics_io_num = -1;  // Manual CS control
    devcfg.queue_size = 4;

    ret = spi_bus_add_device(SPI2_HOST, &devcfg, &dev->spi);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SPI device add failed: %s", esp_err_to_name(ret));
        spi_bus_free(SPI2_HOST);
        vSemaphoreDelete(dev->tx_done_sem);
        free(dev);
        return ret;
    }

    *handle = dev;
    ESP_LOGI(TAG, "SX1276 created (CS=%d, RST=%d, DIO0=%d)",
             spi_config->cs_pin, spi_config->rst_pin, spi_config->dio0_pin);
    return ESP_OK;
}

esp_err_t sx1276_init(sx1276_handle_t handle, const sx1276_lora_config_t *config)
{
    if (!handle || !config) return ESP_ERR_INVALID_ARG;

    handle->lora_config = *config;

    // Hardware reset
    sx1276_hw_reset(handle);

    // Verify chip version (SX1276 should return 0x12)
    uint8_t version = sx1276_read_reg(handle, REG_VERSION);
    if (version != 0x12) {
        ESP_LOGE(TAG, "Unexpected chip version: 0x%02X (expected 0x12)", version);
        return ESP_ERR_NOT_FOUND;
    }
    ESP_LOGI(TAG, "SX1276 chip version: 0x%02X", version);

    // Set sleep mode + LoRa bit (must set LoRa bit in sleep mode)
    sx1276_set_mode(handle, OPMODE_SLEEP);

    // Set standby
    sx1276_set_mode(handle, OPMODE_STANDBY);

    // Set frequency
    sx1276_set_frequency_regs(handle, config->frequency_hz);

    // Set PA config
    sx1276_set_pa_config(handle, config->tx_power_dbm);

    // Set modulation parameters
    sx1276_set_modulation_config(handle, config->sf, config->bw,
                                  config->cr, config->crc_on);

    // Set preamble length
    sx1276_write_reg(handle, REG_PREAMBLE_MSB, (config->preamble_len >> 8) & 0xFF);
    sx1276_write_reg(handle, REG_PREAMBLE_LSB, config->preamble_len & 0xFF);

    // Set FIFO base addresses to 0x00
    sx1276_write_reg(handle, REG_FIFO_TX_BASE_ADDR, 0x00);
    sx1276_write_reg(handle, REG_FIFO_RX_BASE_ADDR, 0x00);

    // Set max payload length
    sx1276_write_reg(handle, REG_MAX_PAYLOAD_LENGTH, 0xFF);

    // LNA boost (highest gain)
    sx1276_write_reg(handle, REG_LNA, sx1276_read_reg(handle, REG_LNA) | 0x03);

    // Clear all IRQ flags
    sx1276_write_reg(handle, REG_IRQ_FLAGS, 0xFF);

    handle->initialized = true;
    ESP_LOGI(TAG, "SX1276 initialized: freq=%luHz, SF%d, BW=%d, power=%ddBm",
             config->frequency_hz, config->sf, config->bw, config->tx_power_dbm);
    return ESP_OK;
}

esp_err_t sx1276_delete(sx1276_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    // Put radio to sleep
    sx1276_set_mode(handle, OPMODE_SLEEP);

    // Remove DIO0 ISR
    if (handle->spi_config.dio0_pin >= 0) {
        gpio_isr_handler_remove((gpio_num_t)handle->spi_config.dio0_pin);
    }

    // Cleanup SPI
    if (handle->spi) {
        spi_bus_remove_device(handle->spi);
    }
    spi_bus_free(SPI2_HOST);

    if (handle->tx_done_sem) {
        vSemaphoreDelete(handle->tx_done_sem);
    }

    free(handle);
    return ESP_OK;
}

esp_err_t sx1276_send(sx1276_handle_t handle, const uint8_t *data, uint8_t len,
                       uint32_t timeout_ms)
{
    if (!handle || !data || len == 0) return ESP_ERR_INVALID_ARG;
    if (!handle->initialized) return ESP_ERR_INVALID_STATE;

    // Set standby
    sx1276_set_mode(handle, OPMODE_STANDBY);

    // Configure DIO0 for TxDone
    sx1276_write_reg(handle, REG_DIO_MAPPING_1, DIO0_TX_DONE);

    // Set FIFO pointer to TX base
    sx1276_write_reg(handle, REG_FIFO_ADDR_PTR, 0x00);

    // Write payload to FIFO
    sx1276_write_fifo(handle, data, len);

    // Set payload length
    sx1276_write_reg(handle, REG_PAYLOAD_LENGTH, len);

    // Clear IRQ flags
    sx1276_write_reg(handle, REG_IRQ_FLAGS, 0xFF);

    // Reset semaphore
    xSemaphoreTake(handle->tx_done_sem, 0);

    // Start TX
    sx1276_set_mode(handle, OPMODE_TX);

    // Wait for TX done via DIO0 ISR
    if (xSemaphoreTake(handle->tx_done_sem, pdMS_TO_TICKS(timeout_ms)) != pdTRUE) {
        ESP_LOGW(TAG, "TX timeout");
        sx1276_set_mode(handle, OPMODE_STANDBY);
        return ESP_ERR_TIMEOUT;
    }

    // Check IRQ flags
    uint8_t irq = sx1276_read_reg(handle, REG_IRQ_FLAGS);
    sx1276_write_reg(handle, REG_IRQ_FLAGS, 0xFF);

    if (irq & IRQ_TX_DONE) {
        ESP_LOGD(TAG, "TX done (%d bytes)", len);
        sx1276_set_mode(handle, OPMODE_STANDBY);
        return ESP_OK;
    }

    ESP_LOGW(TAG, "TX completed with unexpected IRQ: 0x%02X", irq);
    sx1276_set_mode(handle, OPMODE_STANDBY);
    return ESP_FAIL;
}

esp_err_t sx1276_start_receive(sx1276_handle_t handle, sx1276_rx_callback_t callback,
                                void *user_data)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    if (!handle->initialized) return ESP_ERR_INVALID_STATE;

    handle->rx_callback = callback;
    handle->rx_user_data = user_data;

    // Set standby first
    sx1276_set_mode(handle, OPMODE_STANDBY);

    // Configure DIO0 for RxDone
    sx1276_write_reg(handle, REG_DIO_MAPPING_1, DIO0_RX_DONE);

    // Set FIFO pointer to RX base
    sx1276_write_reg(handle, REG_FIFO_ADDR_PTR, 0x00);

    // Clear IRQ flags
    sx1276_write_reg(handle, REG_IRQ_FLAGS, 0xFF);

    // Start continuous RX
    sx1276_set_mode(handle, OPMODE_RX_CONTINUOUS);

    ESP_LOGI(TAG, "Continuous receive started");
    return ESP_OK;
}

esp_err_t sx1276_get_packet(sx1276_handle_t handle, uint8_t *buf, uint8_t buf_len,
                             sx1276_rx_info_t *info)
{
    if (!handle || !buf || !info) return ESP_ERR_INVALID_ARG;

    // Check IRQ flags
    uint8_t irq = sx1276_read_reg(handle, REG_IRQ_FLAGS);

    if (!(irq & IRQ_RX_DONE)) {
        return ESP_ERR_NOT_FOUND;
    }

    // Clear RX done + CRC error flags
    sx1276_write_reg(handle, REG_IRQ_FLAGS, IRQ_RX_DONE | IRQ_PAYLOAD_CRC_ERROR);

    if (irq & IRQ_PAYLOAD_CRC_ERROR) {
        ESP_LOGW(TAG, "RX CRC error");
        return ESP_ERR_INVALID_CRC;
    }

    // Get payload length
    uint8_t payload_len = sx1276_read_reg(handle, REG_RX_NB_BYTES);
    if (payload_len > buf_len) {
        ESP_LOGW(TAG, "RX payload %d exceeds buffer %d", payload_len, buf_len);
        payload_len = buf_len;
    }
    info->len = payload_len;

    // Set FIFO pointer to current RX address
    uint8_t rx_addr = sx1276_read_reg(handle, REG_FIFO_RX_CURRENT_ADDR);
    sx1276_write_reg(handle, REG_FIFO_ADDR_PTR, rx_addr);

    // Read payload from FIFO
    sx1276_read_fifo(handle, buf, payload_len);

    // Get packet SNR and RSSI
    int8_t snr_raw = (int8_t)sx1276_read_reg(handle, REG_PKT_SNR_VALUE);
    info->snr = snr_raw / 4;

    int16_t rssi_raw = (int16_t)sx1276_read_reg(handle, REG_PKT_RSSI_VALUE);
    if (snr_raw < 0) {
        info->rssi = -157 + rssi_raw + (snr_raw / 4);
    } else {
        info->rssi = -157 + (rssi_raw * 16) / 15;
    }

    ESP_LOGD(TAG, "RX: %d bytes, RSSI=%d, SNR=%d", info->len, info->rssi, info->snr);
    return ESP_OK;
}

esp_err_t sx1276_standby(sx1276_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->rx_callback = NULL;
    sx1276_set_mode(handle, OPMODE_STANDBY);
    return ESP_OK;
}

esp_err_t sx1276_sleep(sx1276_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->rx_callback = NULL;
    sx1276_set_mode(handle, OPMODE_SLEEP);
    return ESP_OK;
}

esp_err_t sx1276_set_frequency(sx1276_handle_t handle, uint32_t freq_hz)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.frequency_hz = freq_hz;
    sx1276_set_mode(handle, OPMODE_STANDBY);
    sx1276_set_frequency_regs(handle, freq_hz);
    return ESP_OK;
}

esp_err_t sx1276_set_tx_power(sx1276_handle_t handle, int8_t power_dbm)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.tx_power_dbm = power_dbm;
    sx1276_set_pa_config(handle, power_dbm);
    return ESP_OK;
}

esp_err_t sx1276_set_sf(sx1276_handle_t handle, sx1276_sf_t sf)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.sf = sf;
    sx1276_set_mode(handle, OPMODE_STANDBY);
    sx1276_set_modulation_config(handle, sf, handle->lora_config.bw,
                                  handle->lora_config.cr, handle->lora_config.crc_on);
    return ESP_OK;
}

esp_err_t sx1276_set_bw(sx1276_handle_t handle, sx1276_bw_t bw)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.bw = bw;
    sx1276_set_mode(handle, OPMODE_STANDBY);
    sx1276_set_modulation_config(handle, handle->lora_config.sf, bw,
                                  handle->lora_config.cr, handle->lora_config.crc_on);
    return ESP_OK;
}
