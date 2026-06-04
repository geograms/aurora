#ifndef GEOGRAM_LOG_PLAIN_H
#define GEOGRAM_LOG_PLAIN_H

#include <stdarg.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Print a log line without ANSI color sequences.
 * @param tag Optional tag (can be NULL).
 * @param fmt printf-style format string.
 */
void geogram_log_plain(const char *tag, const char *fmt, ...);

#ifdef __cplusplus
}
#endif

#endif // GEOGRAM_LOG_PLAIN_H
