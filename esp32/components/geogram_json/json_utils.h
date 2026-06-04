#ifndef GEOGRAM_JSON_UTILS_H
#define GEOGRAM_JSON_UTILS_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// JSON builder context
typedef struct {
    char *buffer;
    size_t size;
    size_t pos;
    bool first_field;
    int depth;
} geo_json_builder_t;

// Initialize JSON builder
void geo_json_init(geo_json_builder_t *builder, char *buffer, size_t size);

// Start/end object
void geo_json_object_start(geo_json_builder_t *builder);
void geo_json_object_end(geo_json_builder_t *builder);

// Start/end array
void geo_json_array_start(geo_json_builder_t *builder, const char *key);
void geo_json_array_end(geo_json_builder_t *builder);

// Add fields to object
void geo_json_add_string(geo_json_builder_t *builder, const char *key, const char *value);
void geo_json_add_int(geo_json_builder_t *builder, const char *key, int value);
void geo_json_add_uint(geo_json_builder_t *builder, const char *key, uint32_t value);
void geo_json_add_int64(geo_json_builder_t *builder, const char *key, int64_t value);
void geo_json_add_double(geo_json_builder_t *builder, const char *key, double value, int precision);
void geo_json_add_bool(geo_json_builder_t *builder, const char *key, bool value);

// Get result
const char *geo_json_get_string(geo_json_builder_t *builder);
size_t geo_json_get_length(geo_json_builder_t *builder);

// Simple JSON parsing (extract specific fields)
// Returns true if field found, copies value to output buffer
bool geo_json_get_field_string(const char *json, const char *field, char *output, size_t output_size);
bool geo_json_get_field_int(const char *json, const char *field, int *output);

// Extract nested field from tags array: [["key", "value"], ...]
// Looks for tag with matching key and returns the value
bool geo_json_get_tag_value(const char *json, const char *tag_key, char *output, size_t output_size);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_JSON_UTILS_H
