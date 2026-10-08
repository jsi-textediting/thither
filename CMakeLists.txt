# thither: a small remote-editing server spoken to over ssh stdio.
#
# Standalone:   cmake -S thither -B build -G Ninja -DCMAKE_BUILD_TYPE=Release
# From Lite XL: the editor's CMakeLists.txt add_subdirectory()s this when
#               LITE_BUILD_THITHER is ON and its Lua / PCRE2 targets are reused.
#
# POSIX only (Linux, macOS, BSD). No SDL: the few SDL calls in the editor's
# shared C files resolve to src/compat (pthreads + libc).
#
# Options:
#   THITHER_STATIC      link fully static (glibc warns about dlopen/getpwuid)
#   THITHER_EMBED_LUA   compile lua/thither/*.lua into the binary (default ON)
#   THITHER_LITE_SRC    the Lite XL src/ directory providing system.c,
#                       process.c, dirmonitor.c and regex.c
#   THITHER_DIRMONITOR_BACKEND  inotify | fsevents | kqueue | dummy (auto when empty)
cmake_minimum_required(VERSION 3.21)
project(thither VERSION 0.1.0 LANGUAGES C)

if(WIN32)
    message(FATAL_ERROR "thither-server is POSIX-only (Linux, macOS, BSD)")
endif()

option(THITHER_STATIC "Link thither-server statically" OFF)
option(THITHER_EMBED_LUA "Compile the Lua modules into thither-server" ON)
set(THITHER_LITE_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../src" CACHE PATH
    "Lite XL src/ directory with the shared system/process/dirmonitor/regex sources")
set(THITHER_DIRMONITOR_BACKEND "" CACHE STRING
    "dirmonitor backend: inotify | fsevents | kqueue | dummy (auto when empty)")

include(FetchContent)

# ── Lua 5.5 (reused when the including project already provides it) ────────
if(TARGET lua_static)
    set(_th_lua lua_static)
elseif(TARGET lua_system_shim)
    set(_th_lua lua_system_shim)
else()
    FetchContent_Declare(lua
        URL                      https://www.lua.org/ftp/lua-5.5.1.tar.gz
        URL_HASH                 SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    )
    FetchContent_MakeAvailable(lua)
    file(GLOB _th_lua_sources "${lua_SOURCE_DIR}/src/*.c")
    list(FILTER _th_lua_sources EXCLUDE REGEX "(lua|luac)\\.c$")
    add_library(lua_static STATIC ${_th_lua_sources})
    target_include_directories(lua_static PUBLIC "${lua_SOURCE_DIR}/src")
    set_target_properties(lua_static PROPERTIES C_STANDARD 11 C_EXTENSIONS ON)
    set(_th_lua lua_static)
endif()

# ── PCRE2 10.44 (likewise) ─────────────────────────────────────────────────
if(NOT TARGET pcre2-8)
    set(PCRE2_BUILD_PCRE2_8   ON  CACHE BOOL "" FORCE)
    set(PCRE2_BUILD_PCRE2_16  OFF CACHE BOOL "" FORCE)
    set(PCRE2_BUILD_PCRE2_32  OFF CACHE BOOL "" FORCE)
    set(PCRE2_BUILD_PCRE2_GREP OFF CACHE BOOL "" FORCE)
    set(PCRE2_BUILD_TESTS      OFF CACHE BOOL "" FORCE)
    FetchContent_Declare(pcre2
        URL                      https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2
        URL_HASH                 SHA256=d34f02e113cf7193a1ebf2770d3ac527088d485d4e047ed10e5d217c6ef5de96
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        EXCLUDE_FROM_ALL
    )
    FetchContent_MakeAvailable(pcre2)
endif()

# ── dirmonitor backend ─────────────────────────────────────────────────────
set(_th_dirmon "${THITHER_DIRMONITOR_BACKEND}")
if(_th_dirmon STREQUAL "")
    include(CheckIncludeFile)
    include(CheckFunctionExists)
    if(APPLE)
        check_include_file("CoreServices/CoreServices.h" _th_have_cs)
        set(_th_dirmon "dummy")
        if(_th_have_cs)
            set(_th_dirmon "fsevents")
        endif()
    else()
        check_include_file("sys/inotify.h" _th_have_inotify)
        if(_th_have_inotify)
            set(_th_dirmon "inotify")
        else()
            check_function_exists(kqueue _th_have_kqueue)
            if(_th_have_kqueue)
                set(_th_dirmon "kqueue")
            else()
                set(_th_dirmon "dummy")
            endif()
        endif()
    endif()
endif()
if(NOT _th_dirmon MATCHES "^(inotify|fsevents|kqueue|dummy)$")
    message(FATAL_ERROR "dirmonitor backend '${_th_dirmon}' is not supported by thither-server")
endif()
message(STATUS "thither-server dirmonitor backend: ${_th_dirmon}")

# ── embedded Lua modules ───────────────────────────────────────────────────
set(_th_lua_dir "${CMAKE_CURRENT_SOURCE_DIR}/lua")
set(_th_embed_files "")
if(THITHER_EMBED_LUA)
    file(GLOB _th_embed_files CONFIGURE_DEPENDS RELATIVE "${_th_lua_dir}" "${_th_lua_dir}/thither/*.lua")
    list(SORT _th_embed_files)
endif()
set(_th_embed_deps "")
foreach(_f IN LISTS _th_embed_files)
    list(APPEND _th_embed_deps "${_th_lua_dir}/${_f}")
endforeach()
string(REPLACE ";" "|" _th_embed_arg "${_th_embed_files}")
set(_th_embed_c "${CMAKE_CURRENT_BINARY_DIR}/thither_embedded.c")
add_custom_command(
    OUTPUT "${_th_embed_c}"
    COMMAND "${CMAKE_COMMAND}" "-DOUT=${_th_embed_c}" "-DROOT=${_th_lua_dir}"
            "-DFILES=${_th_embed_arg}" "-DVERSION=${PROJECT_VERSION}"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_lua.cmake"
    DEPENDS ${_th_embed_deps} "${CMAKE_CURRENT_SOURCE_DIR}/cmake/embed_lua.cmake"
    COMMENT "Embedding thither Lua modules"
    VERBATIM
)

# ── thither-server ─────────────────────────────────────────────────────────
set(_th_src "${CMAKE_CURRENT_SOURCE_DIR}/src")
set(_lx "${THITHER_LITE_SRC}")
add_executable(thither-server
    "${_th_src}/main.c"
    "${_th_src}/stdio.c"
    "${_th_src}/fsops.c"
    "${_th_src}/embed.c"
    "${_th_src}/events.c"
    "${_th_src}/compat/sdl_compat.c"
    "${_lx}/api/system.c"
    "${_lx}/api/process.c"
    "${_lx}/api/regex.c"
    "${_lx}/api/dirmonitor.c"
    "${_lx}/api/dirmonitor/${_th_dirmon}.c"
    "${_lx}/arena_allocator.c"
    "${_th_embed_c}"
)
set_target_properties(thither-server PROPERTIES C_STANDARD 11 C_EXTENSIONS ON)
# compat/ first: <SDL3/SDL.h> and "custom_events.h" must resolve to the stand-ins
target_include_directories(thither-server BEFORE PRIVATE
    "${_th_src}/compat"
    "${_th_src}"
    "${_lx}/api"
    "${_lx}"
)
target_compile_definitions(thither-server PRIVATE
    THITHER
    PCRE2_STATIC
    "THITHER_VERSION_STR=\"${PROJECT_VERSION}\""
)
find_package(Threads REQUIRED)
target_link_libraries(thither-server PRIVATE ${_th_lua} pcre2-8 Threads::Threads ${CMAKE_DL_LIBS})
if(APPLE)
    target_link_options(thither-server PRIVATE -framework CoreServices -framework Foundation)
else()
    find_library(_th_m_lib m)
    if(_th_m_lib)
        target_link_libraries(thither-server PRIVATE ${_th_m_lib})
    endif()
endif()
if(THITHER_STATIC AND NOT APPLE)
    target_link_options(thither-server PRIVATE -static)
endif()
# let the linker drop unused code from Lua, PCRE2 and the shared sources
target_compile_options(thither-server PRIVATE -ffunction-sections -fdata-sections)
if(APPLE)
    target_link_options(thither-server PRIVATE -Wl,-dead_strip)
else()
    target_link_options(thither-server PRIVATE -Wl,--gc-sections)
endif()
# the line counter / scanner is the hot loop of lineindex and search
set_source_files_properties("${_th_src}/fsops.c" PROPERTIES COMPILE_OPTIONS "-O2")

# ── install ────────────────────────────────────────────────────────────────
include(GNUInstallDirs)
install(TARGETS thither-server RUNTIME DESTINATION "${CMAKE_INSTALL_BINDIR}")
# with THITHER_EMBED_LUA the binary is self-contained
if(NOT THITHER_EMBED_LUA)
    install(DIRECTORY "${_th_lua_dir}/thither/" DESTINATION "${CMAKE_INSTALL_DATADIR}/thither/thither")
endif()
