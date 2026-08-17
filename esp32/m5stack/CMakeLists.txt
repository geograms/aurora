cmake_minimum_required(VERSION 3.16)
# The shared communication components are symlinked into ./components, which
# PlatformIO/IDF auto-discover. EXTRA_COMPONENT_DIRS pointing outside the
# project dir does not work here — see the note in rns_ble5/CMakeLists.txt.
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(m5stack_xprs)
