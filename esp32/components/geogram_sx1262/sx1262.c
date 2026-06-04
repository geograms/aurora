#include <string.h>
#include <stdlib.h>
#include "sx1262.h"
#include "driver/spi_master.h"
#include "driver/gpio.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"

static const char *TAG = "sx1262";

// SX1262 SPI opcodes
#define SX1262_CMD_SET_SLEEP                0x84
#define SX1262_CMD_SET_STANDBY              0x80
#define SX1262_CMD_SET_TX                   0x83
#define SX1262_CMD_SET_RX                   0x82
#define SX1262_CMD_SET_PACKET_TYPE          0x8A
#define SX1262_CMD_SET_RF_FREQUENCY         0x86
#define SX1262_CMD_SET_PA_CONFIG            0x95
#define SX1262_CMD_SET_TX_PARAMS            0x8E
#define SX1262_CMD_SET_BUFFER_BASE_ADDR     0x8F
#define SX1262_CMD_SET_MODULATION_PARAMS    0x8B
#define SX1262_CMD_SET_PACKET_PARAMS        0x8C
#define SX1262_CMD_SET_DIO_IRQ_PARAMS       0x08
#define SX1262_CMD_CLEAR_IRQ_STATUS         0x02
#define SX1262_CMD_GET_IRQ_STATUS           0x12
#define SX1262_CMD_WRITE_BUFFER             0x0E
#define SX1262_CMD_READ_BUFFER              0x1E
#define SX1262_CMD_GET_RX_BUFFER_STATUS     0x13
#define SX1262_CMD_GET_PACKET_STATUS        0x14
#define SX1262_CMD_SET_DIO3_AS_TCXO_CTRL    0x97
#define SX1262_CMD_SET_DIO2_AS_RF_SWITCH    0x9D
#define SX1262_CMD_CALIBRATE_IMAGE          0x98
#define SX1262_CMD_SET_REGULATOR_MODE       0x96
#define SX1262_CMD_WRITE_REGISTER           0x0D
#define SX1262_CMD_READ_REGISTER            0x1D

// Packet type
#define SX1262_PACKET_TYPE_LORA             0x01

// Standby mode
#define SX1262_STANDBY_RC                   0x00

// IRQ masks
#define SX1262_IRQ_TX_DONE                  (1 << 0)
#define SX1262_IRQ_RX_DONE                  (1 << 1)
#define SX1262_IRQ_PREAMBLE_DETECTED        (1 << 2)
#define SX1262_IRQ_SYNC_WORD_VALID          (1 << 3)
#define SX1262_IRQ_HEADER_VALID             (1 << 4)
#define SX1262_IRQ_HEADER_ERR               (1 << 5)
#define SX1262_IRQ_CRC_ERR                  (1 << 6)
#define SX1262_IRQ_CAD_DONE                 (1 << 7)
#define SX1262_IRQ_CAD_ACTIVITY_DETECTED    (1 << 8)
#define SX1262_IRQ_RX_TX_TIMEOUT            (1 << 9)

// Ramp time
#define SX1262_RAMP_200U                    0x04

// TCXO voltage for Heltec V3
#define SX1262_TCXO_VOLTAGE_1_7V            0x06

// Max busy wait time in ms
#define SX1262_BUSY_TIMEOUT_MS              1000

// SPI clock speed
#define SX1262_SPI_CLOCK_HZ                 (8 * 1000 * 1000)

// OCP register for current limit
#define SX1262_REG_OCP                      0x08E7

struct sx1262_dev {
    sx1262_spi_config_t spi_config;
    sx1262_lora_config_t lora_config;
    spi_device_handle_t spi;
    sx1262_rx_callback_t rx_callback;
    void *rx_user_data;
    SemaphoreHandle_t tx_done_sem;
    bool initialized;
};

// ============================================================================
// SPI helpers
// ============================================================================

static void sx1262_cs_low(sx1262_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.cs_pin, 0);
}

static void sx1262_cs_high(sx1262_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.cs_pin, 1);
}

static esp_err_t sx1262_wait_busy(sx1262_handle_t handle)
{
    int timeout = SX1262_BUSY_TIMEOUT_MS;
    while (gpio_get_level((gpio_num_t)handle->spi_config.busy_pin) == 1) {
        vTaskDelay(pdMS_TO_TICKS(1));
        if (--timeout <= 0) {
            ESP_LOGE(TAG, "BUSY timeout");
            return ESP_ERR_TIMEOUT;
        }
    }
    return ESP_OK;
}

static esp_err_t sx1262_spi_write(sx1262_handle_t handle, const uint8_t *data, size_t len)
{
    spi_transaction_t t = {};
    t.length = len * 8;
    t.tx_buffer = data;
    sx1262_cs_low(handle);
    esp_err_t ret = spi_device_polling_transmit(handle->spi, &t);
    sx1262_cs_high(handle);
    return ret;
}

static esp_err_t sx1262_spi_write_read(sx1262_handle_t handle,
                                        const uint8_t *tx, uint8_t *rx, size_t len)
{
    spi_transaction_t t = {};
    t.length = len * 8;
    t.tx_buffer = tx;
    t.rx_buffer = rx;
    sx1262_cs_low(handle);
    esp_err_t ret = spi_device_polling_transmit(handle->spi, &t);
    sx1262_cs_high(handle);
    return ret;
}

// ============================================================================
// SX1262 commands
// ============================================================================

static esp_err_t sx1262_write_command(sx1262_handle_t handle, uint8_t cmd,
                                       const uint8_t *args, uint8_t nargs)
{
    esp_err_t ret = sx1262_wait_busy(handle);
    if (ret != ESP_OK) return ret;

    uint8_t buf[16];
    buf[0] = cmd;
    if (nargs > 0 && args != NULL) {
        memcpy(&buf[1], args, nargs);
    }
    return sx1262_spi_write(handle, buf, 1 + nargs);
}

static esp_err_t sx1262_read_command(sx1262_handle_t handle, uint8_t cmd,
                                      uint8_t *result, uint8_t nresult)
{
    esp_err_t ret = sx1262_wait_busy(handle);
    if (ret != ESP_OK) return ret;

    // SX1262 read: [cmd] [NOP(status)] [result bytes...]
    uint8_t tx[16] = {0};
    uint8_t rx[16] = {0};
    tx[0] = cmd;
    size_t total = 2 + nresult;  // cmd + status NOP + result bytes

    ret = sx1262_spi_write_read(handle, tx, rx, total);
    if (ret == ESP_OK && result != NULL) {
        memcpy(result, &rx[2], nresult);
    }
    return ret;
}

static esp_err_t sx1262_set_standby(sx1262_handle_t handle)
{
    uint8_t arg = SX1262_STANDBY_RC;
    return sx1262_write_command(handle, SX1262_CMD_SET_STANDBY, &arg, 1);
}

static esp_err_t sx1262_set_packet_type(sx1262_handle_t handle, uint8_t type)
{
    return sx1262_write_command(handle, SX1262_CMD_SET_PACKET_TYPE, &type, 1);
}

static esp_err_t sx1262_set_rf_frequency(sx1262_handle_t handle, uint32_t freq_hz)
{
    // Frequency = freq_hz * 2^25 / 32MHz
    uint32_t frf = (uint32_t)((double)freq_hz / (double)(1 << 25) * (double)(1 << 25)
                    * (double)(1 << 25) / 32000000.0);
    // Simpler calculation
    frf = (uint32_t)((uint64_t)freq_hz * (1 << 25) / 32000000ULL);

    uint8_t args[4];
    args[0] = (frf >> 24) & 0xFF;
    args[1] = (frf >> 16) & 0xFF;
    args[2] = (frf >> 8) & 0xFF;
    args[3] = frf & 0xFF;
    return sx1262_write_command(handle, SX1262_CMD_SET_RF_FREQUENCY, args, 4);
}

static esp_err_t sx1262_set_pa_config(sx1262_handle_t handle, int8_t power_dbm)
{
    // SX1262: paDutyCycle=0x04, hpMax=0x07, deviceSel=0x00, paLut=0x01
    uint8_t args[4] = { 0x04, 0x07, 0x00, 0x01 };
    esp_err_t ret = sx1262_write_command(handle, SX1262_CMD_SET_PA_CONFIG, args, 4);
    if (ret != ESP_OK) return ret;

    // Set TX params: power and ramp time
    // SX1262 power range: -9 to +22 dBm
    if (power_dbm > 22) power_dbm = 22;
    if (power_dbm < -9) power_dbm = -9;

    uint8_t tx_args[2] = { (uint8_t)power_dbm, SX1262_RAMP_200U };
    ret = sx1262_write_command(handle, SX1262_CMD_SET_TX_PARAMS, tx_args, 2);
    if (ret != ESP_OK) return ret;

    // Set OCP to 140mA (for +22dBm operation)
    uint8_t ocp_args[3] = {
        (SX1262_REG_OCP >> 8) & 0xFF,
        SX1262_REG_OCP & 0xFF,
        0x38  // 140mA
    };
    return sx1262_write_command(handle, SX1262_CMD_WRITE_REGISTER, ocp_args, 3);
}

static esp_err_t sx1262_set_modulation_params(sx1262_handle_t handle,
                                                sx1262_sf_t sf, sx1262_bw_t bw, sx1262_cr_t cr)
{
    // Low data rate optimize for SF11/SF12 at BW125
    uint8_t ldro = 0;
    if (bw == SX1262_BW_125 && (sf == SX1262_SF11 || sf == SX1262_SF12)) {
        ldro = 1;
    }

    uint8_t args[4] = { (uint8_t)sf, (uint8_t)bw, (uint8_t)cr, ldro };
    return sx1262_write_command(handle, SX1262_CMD_SET_MODULATION_PARAMS, args, 4);
}

static esp_err_t sx1262_set_packet_params(sx1262_handle_t handle,
                                            uint16_t preamble_len, bool crc_on, uint8_t payload_len)
{
    uint8_t args[6];
    args[0] = (preamble_len >> 8) & 0xFF;
    args[1] = preamble_len & 0xFF;
    args[2] = 0x00;  // Explicit header
    args[3] = payload_len;  // Max payload length
    args[4] = crc_on ? 0x01 : 0x00;
    args[5] = 0x00;  // Standard IQ
    return sx1262_write_command(handle, SX1262_CMD_SET_PACKET_PARAMS, args, 6);
}

static esp_err_t sx1262_set_dio_irq_params(sx1262_handle_t handle,
                                             uint16_t irq_mask, uint16_t dio1_mask)
{
    uint8_t args[8];
    args[0] = (irq_mask >> 8) & 0xFF;
    args[1] = irq_mask & 0xFF;
    args[2] = (dio1_mask >> 8) & 0xFF;
    args[3] = dio1_mask & 0xFF;
    args[4] = 0x00;  // DIO2 mask high
    args[5] = 0x00;  // DIO2 mask low
    args[6] = 0x00;  // DIO3 mask high
    args[7] = 0x00;  // DIO3 mask low
    return sx1262_write_command(handle, SX1262_CMD_SET_DIO_IRQ_PARAMS, args, 8);
}

static esp_err_t sx1262_clear_irq_status(sx1262_handle_t handle, uint16_t mask)
{
    uint8_t args[2] = { (uint8_t)(mask >> 8), (uint8_t)(mask & 0xFF) };
    return sx1262_write_command(handle, SX1262_CMD_CLEAR_IRQ_STATUS, args, 2);
}

static esp_err_t sx1262_calibrate_image(sx1262_handle_t handle, uint32_t freq_hz)
{
    uint8_t args[2];
    if (freq_hz >= 902000000) {
        args[0] = 0xE1;  // 902-928 MHz
        args[1] = 0xE9;
    } else if (freq_hz >= 863000000) {
        args[0] = 0xD7;  // 863-870 MHz
        args[1] = 0xDB;
    } else if (freq_hz >= 470000000) {
        args[0] = 0x75;  // 470-510 MHz
        args[1] = 0x81;
    } else {
        args[0] = 0x6B;  // 430-440 MHz
        args[1] = 0x6F;
    }
    return sx1262_write_command(handle, SX1262_CMD_CALIBRATE_IMAGE, args, 2);
}

// ============================================================================
// DIO1 ISR handler
// ============================================================================

static void IRAM_ATTR sx1262_dio1_isr(void *arg)
{
    sx1262_handle_t handle = (sx1262_handle_t)arg;
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;

    // Signal TX done semaphore
    if (handle->tx_done_sem) {
        xSemaphoreGiveFromISR(handle->tx_done_sem, &xHigherPriorityTaskWoken);
    }

    // Call RX callback if set
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

static void sx1262_hw_reset(sx1262_handle_t handle)
{
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(20));
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 0);
    vTaskDelay(pdMS_TO_TICKS(20));
    gpio_set_level((gpio_num_t)handle->spi_config.rst_pin, 1);
    vTaskDelay(pdMS_TO_TICKS(20));
}

// ============================================================================
// Public API
// ============================================================================

esp_err_t sx1262_create(const sx1262_spi_config_t *spi_config, sx1262_handle_t *handle)
{
    if (!spi_config || !handle) return ESP_ERR_INVALID_ARG;

    struct sx1262_dev *dev = calloc(1, sizeof(struct sx1262_dev));
    if (!dev) return ESP_ERR_NO_MEM;

    dev->spi_config = *spi_config;
    dev->tx_done_sem = xSemaphoreCreateBinary();
    if (!dev->tx_done_sem) {
        free(dev);
        return ESP_ERR_NO_MEM;
    }

    // Configure GPIO: CS, RST as outputs; BUSY, DIO1 as inputs
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

    gpio_config_t in_conf = {
        .pin_bit_mask = (1ULL << spi_config->busy_pin),
        .mode = GPIO_MODE_INPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&in_conf);

    // DIO1 as input with rising edge interrupt
    if (spi_config->dio1_pin >= 0) {
        gpio_config_t dio1_conf = {
            .pin_bit_mask = (1ULL << spi_config->dio1_pin),
            .mode = GPIO_MODE_INPUT,
            .pull_up_en = GPIO_PULLUP_DISABLE,
            .pull_down_en = GPIO_PULLDOWN_DISABLE,
            .intr_type = GPIO_INTR_POSEDGE,
        };
        gpio_config(&dio1_conf);
        gpio_install_isr_service(0);
        gpio_isr_handler_add((gpio_num_t)spi_config->dio1_pin, sx1262_dio1_isr, dev);
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
    devcfg.clock_speed_hz = SX1262_SPI_CLOCK_HZ;
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
    ESP_LOGI(TAG, "SX1262 created (CS=%d, RST=%d, BUSY=%d, DIO1=%d)",
             spi_config->cs_pin, spi_config->rst_pin,
             spi_config->busy_pin, spi_config->dio1_pin);
    return ESP_OK;
}

esp_err_t sx1262_init(sx1262_handle_t handle, const sx1262_lora_config_t *config)
{
    if (!handle || !config) return ESP_ERR_INVALID_ARG;

    handle->lora_config = *config;
    esp_err_t ret;

    // Hardware reset
    sx1262_hw_reset(handle);

    // Set standby
    ret = sx1262_set_standby(handle);
    if (ret != ESP_OK) {
        ESP_LOGE(TAG, "SetStandby failed");
        return ret;
    }

    // TCXO control via DIO3 (Heltec V3 requires this)
    if (config->use_tcxo) {
        uint8_t tcxo_args[4] = {
            SX1262_TCXO_VOLTAGE_1_7V,
            0x00, 0x00, 0x64  // Timeout ~5ms (100 * 15.625us)
        };
        ret = sx1262_write_command(handle, SX1262_CMD_SET_DIO3_AS_TCXO_CTRL, tcxo_args, 4);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "SetDio3AsTcxoCtrl failed");
            return ret;
        }

        // Wait for TCXO to stabilize after setting it
        vTaskDelay(pdMS_TO_TICKS(5));

        // Need to re-enter standby after TCXO config
        ret = sx1262_set_standby(handle);
        if (ret != ESP_OK) return ret;
    }

    // DIO2 as RF switch (Heltec V3 requires this)
    if (config->use_dio2_rf_switch) {
        uint8_t arg = 0x01;  // true
        ret = sx1262_write_command(handle, SX1262_CMD_SET_DIO2_AS_RF_SWITCH, &arg, 1);
        if (ret != ESP_OK) {
            ESP_LOGE(TAG, "SetDio2AsRfSwitch failed");
            return ret;
        }
    }

    // Use DC-DC regulator (more efficient)
    uint8_t reg_mode = 0x01;  // DC-DC
    sx1262_write_command(handle, SX1262_CMD_SET_REGULATOR_MODE, &reg_mode, 1);

    // Set buffer base addresses
    uint8_t buf_args[2] = { 0x00, 0x00 };
    sx1262_write_command(handle, SX1262_CMD_SET_BUFFER_BASE_ADDR, buf_args, 2);

    // Set packet type to LoRa
    ret = sx1262_set_packet_type(handle, SX1262_PACKET_TYPE_LORA);
    if (ret != ESP_OK) return ret;

    // Calibrate image for the frequency band
    ret = sx1262_calibrate_image(handle, config->frequency_hz);
    if (ret != ESP_OK) return ret;

    // Set frequency
    ret = sx1262_set_rf_frequency(handle, config->frequency_hz);
    if (ret != ESP_OK) return ret;

    // Set PA config and TX power
    ret = sx1262_set_pa_config(handle, config->tx_power_dbm);
    if (ret != ESP_OK) return ret;

    // Set modulation parameters
    ret = sx1262_set_modulation_params(handle, config->sf, config->bw, config->cr);
    if (ret != ESP_OK) return ret;

    // Set packet parameters
    ret = sx1262_set_packet_params(handle, config->preamble_len, config->crc_on, 0xFF);
    if (ret != ESP_OK) return ret;

    // Configure DIO1 IRQs: TX done + RX done + timeout
    uint16_t irq_mask = SX1262_IRQ_TX_DONE | SX1262_IRQ_RX_DONE | SX1262_IRQ_RX_TX_TIMEOUT;
    ret = sx1262_set_dio_irq_params(handle, irq_mask, irq_mask);
    if (ret != ESP_OK) return ret;

    // Clear any pending IRQs
    sx1262_clear_irq_status(handle, 0xFFFF);

    handle->initialized = true;
    ESP_LOGI(TAG, "SX1262 initialized: freq=%luHz, SF%d, BW=%d, power=%ddBm",
             config->frequency_hz, config->sf, config->bw, config->tx_power_dbm);
    return ESP_OK;
}

esp_err_t sx1262_delete(sx1262_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;

    // Put radio to sleep
    uint8_t sleep_arg = 0x00;
    sx1262_write_command(handle, SX1262_CMD_SET_SLEEP, &sleep_arg, 1);

    // Remove DIO1 ISR
    if (handle->spi_config.dio1_pin >= 0) {
        gpio_isr_handler_remove((gpio_num_t)handle->spi_config.dio1_pin);
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

esp_err_t sx1262_send(sx1262_handle_t handle, const uint8_t *data, uint8_t len,
                       uint32_t timeout_ms)
{
    if (!handle || !data || len == 0) return ESP_ERR_INVALID_ARG;
    if (!handle->initialized) return ESP_ERR_INVALID_STATE;

    esp_err_t ret;

    // Set standby before configuring TX
    ret = sx1262_set_standby(handle);
    if (ret != ESP_OK) return ret;

    // Update packet params with actual payload length
    ret = sx1262_set_packet_params(handle, handle->lora_config.preamble_len,
                                    handle->lora_config.crc_on, len);
    if (ret != ESP_OK) return ret;

    // Write payload to buffer at offset 0
    ret = sx1262_wait_busy(handle);
    if (ret != ESP_OK) return ret;

    uint8_t hdr[2] = { SX1262_CMD_WRITE_BUFFER, 0x00 };
    sx1262_cs_low(handle);
    spi_transaction_t t1 = {};
    t1.length = 16;
    t1.tx_buffer = hdr;
    spi_device_polling_transmit(handle->spi, &t1);
    spi_transaction_t t2 = {};
    t2.length = len * 8;
    t2.tx_buffer = data;
    spi_device_polling_transmit(handle->spi, &t2);
    sx1262_cs_high(handle);

    // Clear IRQ and reset semaphore
    sx1262_clear_irq_status(handle, 0xFFFF);
    xSemaphoreTake(handle->tx_done_sem, 0);  // Reset

    // Set TX with timeout (timeout = timeout_ms * 64 ticks at 15.625us per tick)
    uint32_t timeout_ticks = (uint32_t)((uint64_t)timeout_ms * 64);
    uint8_t tx_args[3] = {
        (uint8_t)((timeout_ticks >> 16) & 0xFF),
        (uint8_t)((timeout_ticks >> 8) & 0xFF),
        (uint8_t)(timeout_ticks & 0xFF),
    };
    ret = sx1262_write_command(handle, SX1262_CMD_SET_TX, tx_args, 3);
    if (ret != ESP_OK) return ret;

    // Wait for TX done via DIO1 ISR
    if (xSemaphoreTake(handle->tx_done_sem, pdMS_TO_TICKS(timeout_ms + 500)) != pdTRUE) {
        ESP_LOGW(TAG, "TX timeout");
        sx1262_set_standby(handle);
        return ESP_ERR_TIMEOUT;
    }

    // Verify TX done IRQ
    uint8_t irq_status[2] = {0};
    sx1262_read_command(handle, SX1262_CMD_GET_IRQ_STATUS, irq_status, 2);
    uint16_t irq = ((uint16_t)irq_status[0] << 8) | irq_status[1];
    sx1262_clear_irq_status(handle, 0xFFFF);

    if (irq & SX1262_IRQ_TX_DONE) {
        ESP_LOGD(TAG, "TX done (%d bytes)", len);
        return ESP_OK;
    }

    ESP_LOGW(TAG, "TX completed with unexpected IRQ: 0x%04X", irq);
    return ESP_FAIL;
}

esp_err_t sx1262_start_receive(sx1262_handle_t handle, sx1262_rx_callback_t callback,
                                void *user_data)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    if (!handle->initialized) return ESP_ERR_INVALID_STATE;

    handle->rx_callback = callback;
    handle->rx_user_data = user_data;

    esp_err_t ret = sx1262_set_standby(handle);
    if (ret != ESP_OK) return ret;

    // Set packet params for max receive
    ret = sx1262_set_packet_params(handle, handle->lora_config.preamble_len,
                                    handle->lora_config.crc_on, 0xFF);
    if (ret != ESP_OK) return ret;

    sx1262_clear_irq_status(handle, 0xFFFF);

    // Start continuous RX (timeout = 0xFFFFFF)
    uint8_t rx_args[3] = { 0xFF, 0xFF, 0xFF };
    ret = sx1262_write_command(handle, SX1262_CMD_SET_RX, rx_args, 3);
    if (ret != ESP_OK) return ret;

    ESP_LOGI(TAG, "Continuous receive started");
    return ESP_OK;
}

esp_err_t sx1262_get_packet(sx1262_handle_t handle, uint8_t *buf, uint8_t buf_len,
                             sx1262_rx_info_t *info)
{
    if (!handle || !buf || !info) return ESP_ERR_INVALID_ARG;

    // Check IRQ status
    uint8_t irq_status[2] = {0};
    esp_err_t ret = sx1262_read_command(handle, SX1262_CMD_GET_IRQ_STATUS, irq_status, 2);
    if (ret != ESP_OK) return ret;

    uint16_t irq = ((uint16_t)irq_status[0] << 8) | irq_status[1];
    if (!(irq & SX1262_IRQ_RX_DONE)) {
        return ESP_ERR_NOT_FOUND;
    }

    // Clear RX done IRQ
    sx1262_clear_irq_status(handle, SX1262_IRQ_RX_DONE | SX1262_IRQ_CRC_ERR);

    if (irq & SX1262_IRQ_CRC_ERR) {
        ESP_LOGW(TAG, "RX CRC error");
        return ESP_ERR_INVALID_CRC;
    }

    // Get RX buffer status (payload length + start offset)
    uint8_t rx_status[2] = {0};
    ret = sx1262_read_command(handle, SX1262_CMD_GET_RX_BUFFER_STATUS, rx_status, 2);
    if (ret != ESP_OK) return ret;

    uint8_t payload_len = rx_status[0];
    uint8_t start_offset = rx_status[1];

    if (payload_len > buf_len) {
        ESP_LOGW(TAG, "RX payload %d exceeds buffer %d", payload_len, buf_len);
        payload_len = buf_len;
    }
    info->len = payload_len;

    // Read payload from buffer
    ret = sx1262_wait_busy(handle);
    if (ret != ESP_OK) return ret;

    uint8_t read_hdr[3] = { SX1262_CMD_READ_BUFFER, start_offset, 0x00 };  // cmd + offset + NOP
    uint8_t read_rx[3] = {0};
    sx1262_cs_low(handle);
    spi_transaction_t t1 = {};
    t1.length = 24;
    t1.tx_buffer = read_hdr;
    t1.rx_buffer = read_rx;
    spi_device_polling_transmit(handle->spi, &t1);
    // Now read the payload
    uint8_t dummy_tx[256] = {0};
    spi_transaction_t t2 = {};
    t2.length = payload_len * 8;
    t2.tx_buffer = dummy_tx;
    t2.rx_buffer = buf;
    spi_device_polling_transmit(handle->spi, &t2);
    sx1262_cs_high(handle);

    // Get packet status (RSSI, SNR)
    uint8_t pkt_status[3] = {0};
    ret = sx1262_read_command(handle, SX1262_CMD_GET_PACKET_STATUS, pkt_status, 3);
    if (ret == ESP_OK) {
        info->rssi = -(int16_t)(pkt_status[0] / 2);
        info->snr = (int8_t)pkt_status[1] / 4;
    }

    ESP_LOGD(TAG, "RX: %d bytes, RSSI=%d, SNR=%d", info->len, info->rssi, info->snr);
    return ESP_OK;
}

esp_err_t sx1262_standby(sx1262_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->rx_callback = NULL;
    return sx1262_set_standby(handle);
}

esp_err_t sx1262_sleep(sx1262_handle_t handle)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->rx_callback = NULL;
    uint8_t arg = 0x04;  // Warm start (retain config)
    return sx1262_write_command(handle, SX1262_CMD_SET_SLEEP, &arg, 1);
}

esp_err_t sx1262_set_frequency(sx1262_handle_t handle, uint32_t freq_hz)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.frequency_hz = freq_hz;
    esp_err_t ret = sx1262_set_standby(handle);
    if (ret != ESP_OK) return ret;
    ret = sx1262_calibrate_image(handle, freq_hz);
    if (ret != ESP_OK) return ret;
    return sx1262_set_rf_frequency(handle, freq_hz);
}

esp_err_t sx1262_set_tx_power(sx1262_handle_t handle, int8_t power_dbm)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.tx_power_dbm = power_dbm;
    return sx1262_set_pa_config(handle, power_dbm);
}

esp_err_t sx1262_set_sf(sx1262_handle_t handle, sx1262_sf_t sf)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.sf = sf;
    return sx1262_set_modulation_params(handle, sf, handle->lora_config.bw, handle->lora_config.cr);
}

esp_err_t sx1262_set_bw(sx1262_handle_t handle, sx1262_bw_t bw)
{
    if (!handle) return ESP_ERR_INVALID_ARG;
    handle->lora_config.bw = bw;
    return sx1262_set_modulation_params(handle, handle->lora_config.sf, bw, handle->lora_config.cr);
}
