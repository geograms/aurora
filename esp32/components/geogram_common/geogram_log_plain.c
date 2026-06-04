#include "geogram_log_plain.h"

#include <stdio.h>
#include <string.h>

static void strip_ansi(const char *in, char *out, size_t out_len)
{
    size_t o = 0;
    for (size_t i = 0; in[i] != '\0' && o + 1 < out_len; i++) {
        if (in[i] == '\x1b' && in[i + 1] == '[') {
            i += 2;
            while (in[i] != '\0' && in[i] != 'm') {
                i++;
            }
            continue;
        }
        out[o++] = in[i];
    }
    out[o] = '\0';
}

void geogram_log_plain(const char *tag, const char *fmt, ...)
{
    char buf[512];
    char clean[512];

    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    strip_ansi(buf, clean, sizeof(clean));

    if (tag && tag[0] != '\0') {
        printf("%s: %s\n", tag, clean);
    } else {
        printf("%s\n", clean);
    }
}
