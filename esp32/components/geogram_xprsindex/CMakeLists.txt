# The XPRS index (SD-backed) — see xprsindex.h.
#
# Registered on every target, unlike geogram_msgstore/geogram_sdcard: nothing
# here touches SDMMC. It is stdio over whatever VFS the caller's directory lives
# on, so gating it by IDF_TARGET would only cost dependents their include path.
# It stays dead code where xprsindex_open() is never called.
#
# test_xprsindex_host.c / test_sha256_host.c are a HOST gcc harness (run
# test_xprsindex_host.sh) and are deliberately not listed in SRCS — same
# arrangement as geogram_xprs/test_xprs_host.c.
idf_component_register(
    SRCS "xprsindex.c"
    INCLUDE_DIRS "."
    REQUIRES geogram_xprs fatfs vfs log esp_timer)
