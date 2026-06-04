#include "json_utils.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#define TAG "JSON"

void geo_json_init(geo_json_builder_t *builder, char *buffer, size_t size) {
    builder->buffer = buffer;
    builder->size = size;
    builder->pos = 0;
    builder->first_field = true;
    builder->depth = 0;
    if (size > 0) {
        buffer[0] = '\0';
    }
}

static void geo_json_append(geo_json_builder_t *builder, const char *str) {
    size_t len = strlen(str);
    if (builder->pos + len < builder->size) {
        strcpy(builder->buffer + builder->pos, str);
        builder->pos += len;
    }
}

static void geo_json_append_escaped(geo_json_builder_t *builder, const char *str) {
    geo_json_append(builder, "\"");
    while (*str && builder->pos < builder->size - 2) {
        char c = *str++;
        if (c == '"' || c == '\\') {
            builder->buffer[builder->pos++] = '\\';
        } else if (c == '\n') {
            builder->buffer[builder->pos++] = '\\';
            c = 'n';
        } else if (c == '\r') {
            builder->buffer[builder->pos++] = '\\';
            c = 'r';
        } else if (c == '\t') {
            builder->buffer[builder->pos++] = '\\';
            c = 't';
        }
        builder->buffer[builder->pos++] = c;
    }
    builder->buffer[builder->pos] = '\0';
    geo_json_append(builder, "\"");
}

static void geo_json_add_comma(geo_json_builder_t *builder) {
    if (!builder->first_field) {
        geo_json_append(builder, ",");
    }
    builder->first_field = false;
}

void geo_json_object_start(geo_json_builder_t *builder) {
    geo_json_append(builder, "{");
    builder->first_field = true;
    builder->depth++;
}

void geo_json_object_end(geo_json_builder_t *builder) {
    geo_json_append(builder, "}");
    builder->depth--;
    builder->first_field = false;
}

void geo_json_array_start(geo_json_builder_t *builder, const char *key) {
    geo_json_add_comma(builder);
    geo_json_append(builder, "\"");
    geo_json_append(builder, key);
    geo_json_append(builder, "\":[");
    builder->first_field = true;
}

void geo_json_array_end(geo_json_builder_t *builder) {
    geo_json_append(builder, "]");
    builder->first_field = false;
}

void geo_json_add_string(geo_json_builder_t *builder, const char *key, const char *value) {
    geo_json_add_comma(builder);
    geo_json_append(builder, "\"");
    geo_json_append(builder, key);
    geo_json_append(builder, "\":");
    geo_json_append_escaped(builder, value);
}

void geo_json_add_int(geo_json_builder_t *builder, const char *key, int value) {
    geo_json_add_comma(builder);
    char buf[32];
    snprintf(buf, sizeof(buf), "\"%s\":%d", key, value);
    geo_json_append(builder, buf);
}

void geo_json_add_uint(geo_json_builder_t *builder, const char *key, uint32_t value) {
    geo_json_add_comma(builder);
    char buf[32];
    snprintf(buf, sizeof(buf), "\"%s\":%lu", key, (unsigned long)value);
    geo_json_append(builder, buf);
}

void geo_json_add_int64(geo_json_builder_t *builder, const char *key, int64_t value) {
    geo_json_add_comma(builder);
    char buf[48];
    snprintf(buf, sizeof(buf), "\"%s\":%lld", key, (long long)value);
    geo_json_append(builder, buf);
}

void geo_json_add_double(geo_json_builder_t *builder, const char *key, double value, int precision) {
    geo_json_add_comma(builder);
    char buf[48];
    snprintf(buf, sizeof(buf), "\"%s\":%.*f", key, precision, value);
    geo_json_append(builder, buf);
}

void geo_json_add_bool(geo_json_builder_t *builder, const char *key, bool value) {
    geo_json_add_comma(builder);
    char buf[32];
    snprintf(buf, sizeof(buf), "\"%s\":%s", key, value ? "true" : "false");
    geo_json_append(builder, buf);
}

const char *geo_json_get_string(geo_json_builder_t *builder) {
    return builder->buffer;
}

size_t geo_json_get_length(geo_json_builder_t *builder) {
    return builder->pos;
}

// Simple JSON field extraction (no full parser, just string search)
bool geo_json_get_field_string(const char *json, const char *field, char *output, size_t output_size) {
    if (!json || !field || !output || output_size == 0) {
        return false;
    }

    // Build search pattern: "field":"
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":\"", field);

    const char *start = strstr(json, pattern);
    if (!start) {
        return false;
    }

    start += strlen(pattern);

    // Find end quote (handle escaped quotes)
    const char *end = start;
    while (*end && *end != '"') {
        if (*end == '\\' && *(end + 1)) {
            end += 2;  // Skip escaped char
        } else {
            end++;
        }
    }

    size_t len = end - start;
    if (len >= output_size) {
        len = output_size - 1;
    }

    strncpy(output, start, len);
    output[len] = '\0';

    return true;
}

bool geo_json_get_field_int(const char *json, const char *field, int *output) {
    if (!json || !field || !output) {
        return false;
    }

    // Build search pattern: "field":
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "\"%s\":", field);

    const char *start = strstr(json, pattern);
    if (!start) {
        return false;
    }

    start += strlen(pattern);

    // Skip whitespace
    while (*start == ' ' || *start == '\t') {
        start++;
    }

    *output = atoi(start);
    return true;
}

// Extract value from tags array: [["key", "value"], ["key2", "value2"]]
bool geo_json_get_tag_value(const char *json, const char *tag_key, char *output, size_t output_size) {
    if (!json || !tag_key || !output || output_size == 0) {
        return false;
    }

    // Find "tags": array
    const char *tags = strstr(json, "\"tags\":");
    if (!tags) {
        return false;
    }

    // Build search pattern: ["key","
    char pattern[64];
    snprintf(pattern, sizeof(pattern), "[\"%s\",\"", tag_key);

    const char *start = strstr(tags, pattern);
    if (!start) {
        // Try alternate format: ["key", " (with space)
        snprintf(pattern, sizeof(pattern), "[\"%s\", \"", tag_key);
        start = strstr(tags, pattern);
        if (!start) {
            return false;
        }
    }

    // Find the value after the key
    start = strchr(start + 2, ',');  // Skip past key
    if (!start) {
        return false;
    }

    // Skip to opening quote of value
    start = strchr(start, '"');
    if (!start) {
        return false;
    }
    start++;  // Skip the quote

    // Find closing quote
    const char *end = strchr(start, '"');
    if (!end) {
        return false;
    }

    size_t len = end - start;
    if (len >= output_size) {
        len = output_size - 1;
    }

    strncpy(output, start, len);
    output[len] = '\0';

    return true;
}
