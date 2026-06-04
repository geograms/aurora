

idf_component_register(SRCS "src/ssh_server.c"
                       INCLUDE_DIRS "include"
                       REQUIRES "david-cermak__libssh"
                       PRIV_REQUIRES "vfs" "esp_timer"
                       )

# Disable format warnings for this component (has issues with PRIu32 format strings)
set_source_files_properties(src/ssh_server.c PROPERTIES
    COMPILE_FLAGS "-Wno-format"
)
