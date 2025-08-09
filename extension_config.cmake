# This file is included by DuckDB's build system. It specifies which extension to load

# Circe native image build (refactored to external script for readability)
string(TOLOWER "${CMAKE_SYSTEM_NAME}" CIRCE_SYS_LOWER)
set(CIRCE_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
set(CIRCE_BE_DIR "${CMAKE_CURRENT_LIST_DIR}/circe-be")
set(GRAAL_CONF_DIR "${CMAKE_CURRENT_LIST_DIR}/graalvm-config")
set(CIRCE_NATIVE_DIR "${CIRCE_BE_DIR}/native-libs/${CIRCE_SYS_LOWER}-${CIRCE_ARCH}")
set(CIRCE_NATIVE_SO "${CIRCE_NATIVE_DIR}/libcirce-native.so")
set(CIRCE_NATIVE_BUILD_STAMP "${CIRCE_BE_DIR}/native-libs/BUILD_INFO.txt")
option(CIRCE_KEEP_NATIVE_SO "Keep built circe-native.so after embedding" OFF)
find_program(MAVEN_CMD mvn REQUIRED)
find_program(NATIVE_IMAGE_CMD native-image REQUIRED)
find_program(BASH_CMD bash REQUIRED)

# Build script written at configure time
set(CIRCE_BUILD_SCRIPT "${CMAKE_CURRENT_BINARY_DIR}/build_circe_native.sh")
file(WRITE ${CIRCE_BUILD_SCRIPT} "#!/usr/bin/env bash\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "set -euo pipefail\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "echo '[circe-native] Maven build'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "mvn -q -DskipTests -Dmaven.test.skip=true -Djacoco.skip=true -Dskip.unit.tests=true clean package dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=target/classpath.txt\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "cp target/circe-*.jar target/circe-cli.jar\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "mkdir -p target/bootstrap\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "cat > target/bootstrap/CirceBootstrapMain.java <<'JAV'\npublic class CirceBootstrapMain { public static void main(String[] a){ System.out.println(\"Circe native image bootstrap\"); } }\nJAV\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "javac -cp target/circe-cli.jar -d target/bootstrap target/bootstrap/CirceBootstrapMain.java\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "CP=$(tr -d '\r' < target/classpath.txt)\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "echo '[circe-native] native-image'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "${NATIVE_IMAGE_CMD} --no-fallback --shared --enable-all-security-services -H:+ReportExceptionStackTraces -J-Xss8m -J-Xmx2g -H:ConfigurationFileDirectories='${GRAAL_CONF_DIR}' --initialize-at-build-time=org.ohdsi.circe,com.fasterxml.jackson -H:Name=circe-native -cp target/circe-cli.jar:target/bootstrap:$CP -H:Class=CirceBootstrapMain\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "mkdir -p '${CIRCE_NATIVE_DIR}'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "mv -f circe-native.so '${CIRCE_NATIVE_SO}'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "cp -f target/circe-cli.jar '${CIRCE_NATIVE_DIR}/'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "{ echo 'Build Timestamp: '$(date -u +'%Y-%m-%dT%H:%M:%SZ'); echo 'Git Commit: '$(git rev-parse --short HEAD 2>/dev/null || echo unknown); echo 'OS: ${CIRCE_SYS_LOWER}'; echo 'Arch: ${CIRCE_ARCH}'; echo 'Jar: circe-cli.jar'; echo 'Native Library: libcirce-native.so'; } > native-libs/BUILD_INFO.txt\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "echo '[circe-native] Done (native lib: ${CIRCE_NATIVE_SO})'\n")
file(APPEND ${CIRCE_BUILD_SCRIPT} "exit 0\n")
execute_process(COMMAND chmod 0755 ${CIRCE_BUILD_SCRIPT})

add_custom_command(
  OUTPUT ${CIRCE_NATIVE_SO} ${CIRCE_NATIVE_BUILD_STAMP}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${GRAAL_CONF_DIR}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CIRCE_NATIVE_DIR}
  COMMAND ${BASH_CMD} ${CIRCE_BUILD_SCRIPT}
  DEPENDS ${CMAKE_CURRENT_LIST_DIR}/graalvm-config/reflect-config.json ${CMAKE_CURRENT_LIST_DIR}/graalvm-config/resource-config.json
  WORKING_DIRECTORY ${CIRCE_BE_DIR}
  COMMENT "Building Circe native shared library via script (GraalVM native-image)"
  VERBATIM
)
add_custom_target(circe_native ALL DEPENDS ${CIRCE_NATIVE_SO} ${CIRCE_NATIVE_BUILD_STAMP})

# Embedding the native library into a header
find_program(XXD_EXECUTABLE xxd)
if(XXD_EXECUTABLE)
  if(NOT TARGET circe_embed_header)
    set(CIRCE_EMBED_HEADER "${CMAKE_CURRENT_BINARY_DIR}/circe_native_embedded.h")
    add_custom_command(
      OUTPUT ${CIRCE_EMBED_HEADER}
      COMMAND ${XXD_EXECUTABLE} -i -n circe_native_blob ${CIRCE_NATIVE_SO} > ${CIRCE_EMBED_HEADER}.tmp
      COMMAND ${CMAKE_COMMAND} -E rename ${CIRCE_EMBED_HEADER}.tmp ${CIRCE_EMBED_HEADER}
      DEPENDS circe_native ${CIRCE_NATIVE_SO}
      COMMENT "Embedding Circe native library (circe_native_embedded.h)"
      VERBATIM
    )
    add_custom_target(circe_embed_header ALL DEPENDS ${CIRCE_EMBED_HEADER})
  endif()
else()
  message(WARNING "xxd not found; Circe native library will not be embedded")
endif()

# circe extension configured; source renamed from quack_extension.cpp to circe_extension.cpp
# Enable embedding globally first
add_compile_definitions(CIRCE_EMBEDDED_NATIVE_LIB)

# Load the extension
duckdb_extension_load(circe
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# Configure targets with proper dependency management using CMake's deferred evaluation
function(configure_circe_extension_dependencies)
  message(STATUS "Configuring Circe extension dependencies...")
  
  if (TARGET circe_extension)
    target_include_directories(circe_extension PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/include/circe_native)
    target_include_directories(circe_extension PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
    target_compile_definitions(circe_extension PRIVATE CIRCE_EMBEDDED_NATIVE_LIB)
    if (TARGET circe_native)
      add_dependencies(circe_extension circe_native)
    endif()
    if (TARGET circe_embed_header)
      add_dependencies(circe_extension circe_embed_header)
    endif()
    message(STATUS "Configured circe_extension with embedding support")
  endif()
  
  if (TARGET circe_loadable_extension)
    target_include_directories(circe_loadable_extension PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/include/circe_native)
    target_include_directories(circe_loadable_extension PRIVATE ${CMAKE_CURRENT_BINARY_DIR})
    target_compile_definitions(circe_loadable_extension PRIVATE CIRCE_EMBEDDED_NATIVE_LIB)
    if (TARGET circe_native)
      add_dependencies(circe_loadable_extension circe_native)
    endif()
    if (TARGET circe_embed_header)
      add_dependencies(circe_loadable_extension circe_embed_header)
    endif()
    message(STATUS "Configured circe_loadable_extension with embedding support")
  endif()
endfunction()

# Use CMake's deferred execution to ensure targets exist before configuring them
cmake_language(DEFER CALL configure_circe_extension_dependencies)
