cmake_minimum_required(VERSION 3.5)

# Set extension name here
set(TARGET_NAME circe)

# DuckDB's extension distribution supports vcpkg. As such, dependencies can be added in ./vcpkg.json and then
# used in cmake with find_package. Feel free to remove or replace with other dependencies.
# Note that it should also be removed from vcpkg.json to prevent needlessly installing it..
find_package(OpenSSL REQUIRED)

set(EXTENSION_NAME ${TARGET_NAME}_extension)
set(LOADABLE_EXTENSION_NAME ${TARGET_NAME}_loadable_extension)

project(${TARGET_NAME})
include_directories(src/include)

# Ensure only circe_extension.cpp is referenced
set(EXTENSION_SOURCES src/circe_extension.cpp)

build_static_extension(${TARGET_NAME} ${EXTENSION_SOURCES})
build_loadable_extension(${TARGET_NAME} " " ${EXTENSION_SOURCES})

# Link OpenSSL in both the static library as the loadable extension
target_link_libraries(${EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto)
target_link_libraries(${LOADABLE_EXTENSION_NAME} OpenSSL::SSL OpenSSL::Crypto)

# BEGIN: Embed circe native library into loadable extension (Linux only, via header array)
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
        set(NATIVE_LIB_SUBDIR "linux-x86_64")
    elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
        set(NATIVE_LIB_SUBDIR "linux-aarch64")
    else()
        set(NATIVE_LIB_SUBDIR "linux-${CMAKE_SYSTEM_PROCESSOR}")
    endif()
    set(CIRCE_NATIVE_LIB "${CMAKE_CURRENT_SOURCE_DIR}/circe-be/native-libs/${NATIVE_LIB_SUBDIR}/libcirce-native.so")
    if(EXISTS ${CIRCE_NATIVE_LIB})
        find_program(XXD_EXECUTABLE xxd)
        if(XXD_EXECUTABLE)
            set(EMBED_HEADER "${CMAKE_CURRENT_BINARY_DIR}/circe_native_embedded.h")
            add_custom_command(OUTPUT ${EMBED_HEADER}
                COMMAND ${XXD_EXECUTABLE} -i -n circe_native_blob ${CIRCE_NATIVE_LIB} > ${EMBED_HEADER}
                DEPENDS ${CIRCE_NATIVE_LIB}
                COMMENT "Embedding Circe native library as C array header")
            add_custom_target(circe_embed_header DEPENDS ${EMBED_HEADER})
            add_dependencies(${LOADABLE_EXTENSION_NAME} circe_embed_header)
            target_include_directories(${LOADABLE_EXTENSION_NAME} PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
            target_compile_definitions(${LOADABLE_EXTENSION_NAME} PRIVATE CIRCE_EMBEDDED_NATIVE_LIB)
            message(STATUS "Circe native library will be embedded (header array) inside circe.duckdb_extension")
            set(CIRCE_EMBED_DONE TRUE)
        else()
            message(WARNING "xxd not found; cannot embed circe native library")
        endif()
    else()
        message(WARNING "Circe native library not found for embedding at ${CIRCE_NATIVE_LIB}")
    endif()
endif()

# If not embedded (non-Linux or missing), fall back to copying next to the extension (previous behavior)
if(NOT CIRCE_EMBED_DONE)
    # Detect OS and architecture for the native library path (original logic)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
            set(NATIVE_LIB_SUBDIR "linux-x86_64")
        elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64")
            set(NATIVE_LIB_SUBDIR "linux-aarch64")
        else()
            set(NATIVE_LIB_SUBDIR "linux-${CMAKE_SYSTEM_PROCESSOR}")
        endif()
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Darwin")
        if(CMAKE_SYSTEM_PROCESSOR STREQUAL "x86_64")
            set(NATIVE_LIB_SUBDIR "darwin-x86_64")
        elseif(CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64")
            set(NATIVE_LIB_SUBDIR "darwin-aarch64")
        else()
            set(NATIVE_LIB_SUBDIR "darwin-${CMAKE_SYSTEM_PROCESSOR}")
        endif()
    elseif(CMAKE_SYSTEM_NAME STREQUAL "Windows")
        set(NATIVE_LIB_SUBDIR "windows-x86_64")
    else()
        set(NATIVE_LIB_SUBDIR "linux-x86_64")
    endif()
    set(CIRCE_NATIVE_LIB "${CMAKE_CURRENT_SOURCE_DIR}/circe-be/native-libs/${NATIVE_LIB_SUBDIR}/libcirce-native.so")
    if(EXISTS ${CIRCE_NATIVE_LIB})
        add_custom_command(TARGET ${LOADABLE_EXTENSION_NAME} POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
            ${CIRCE_NATIVE_LIB}
            $<TARGET_FILE_DIR:${LOADABLE_EXTENSION_NAME}>
            COMMENT "Copying Circe native library (${NATIVE_LIB_SUBDIR}) alongside loadable extension (fallback)"
        )
    else()
        message(WARNING "Circe native library not found at ${CIRCE_NATIVE_LIB} (fallback copy phase)")
    endif()
endif()
# END embedding logic

install(
  TARGETS ${EXTENSION_NAME}
  EXPORT "${DUCKDB_EXPORT_SET}"
  LIBRARY DESTINATION "${INSTALL_LIB_DIR}"
  ARCHIVE DESTINATION "${INSTALL_LIB_DIR}")
