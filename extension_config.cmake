# This file is included by DuckDB's build system. It specifies which extension to load

# Build Circe native shared library (GraalVM) before compiling extension
# Uses the Makefile circe-native target which uses curated graalvm-config.
# If native-image is not available the build will fail; ensure GraalVM with native-image is on PATH.
# Build Circe native shared library (GraalVM) before compiling extension
# Fully managed in CMake (no Makefile invocation)
string(TOLOWER "${CMAKE_SYSTEM_NAME}" CIRCE_SYS_LOWER)
set(CIRCE_ARCH "${CMAKE_SYSTEM_PROCESSOR}")
set(CIRCE_BE_DIR "${CMAKE_CURRENT_LIST_DIR}/circe-be")
set(GRAAL_CONF_DIR "${CMAKE_CURRENT_LIST_DIR}/graalvm-config")
set(CIRCE_NATIVE_DIR "${CIRCE_BE_DIR}/native-libs/${CIRCE_SYS_LOWER}-${CIRCE_ARCH}")
set(CIRCE_NATIVE_SO "${CIRCE_NATIVE_DIR}/libcirce-native.so")
set(CIRCE_NATIVE_BUILD_STAMP "${CMAKE_CURRENT_LIST_DIR}/circe-be/native-libs/BUILD_INFO.txt")
find_program(MAVEN_CMD mvn REQUIRED)
find_program(NATIVE_IMAGE_CMD native-image REQUIRED)

add_custom_command(
  OUTPUT ${CIRCE_NATIVE_SO} ${CIRCE_NATIVE_BUILD_STAMP}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${GRAAL_CONF_DIR}
  COMMAND ${CMAKE_COMMAND} -E make_directory ${CIRCE_NATIVE_DIR}
  COMMAND /bin/sh -c "set -e; cd '${CIRCE_BE_DIR}';     ${MAVEN_CMD} -q -DskipTests -Dmaven.test.skip=true -Djacoco.skip=true -Dskip.unit.tests=true clean package dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=target/classpath.txt;     cp target/circe-*.jar target/circe-cli.jar;     mkdir -p target/bootstrap;     echo 'public class CirceBootstrapMain { public static void main(String[] a){ System.out.println("Circe native image bootstrap"); } }' > target/bootstrap/CirceBootstrapMain.java;     javac -cp target/circe-cli.jar -d target/bootstrap target/bootstrap/CirceBootstrapMain.java;     CP=\$(tr -d '' < target/classpath.txt);     ${NATIVE_IMAGE_CMD} --no-fallback --shared --enable-all-security-services -H:+ReportExceptionStackTraces -J-Xss8m -J-Xmx2g -H:ConfigurationFileDirectories='${GRAAL_CONF_DIR}' --initialize-at-build-time=org.ohdsi.circe,com.fasterxml.jackson -H:Name=circe-native -cp target/circe-cli.jar:target/bootstrap:$$CP -H:Class=CirceBootstrapMain;     mv -f circe-native.so '${CIRCE_NATIVE_SO}';     cp -f target/circe-cli.jar '${CIRCE_NATIVE_DIR}/';     echo "Build Timestamp: \$(date -u +%Y-%m-%dT%H:%M:%SZ)" > native-libs/BUILD_INFO.txt;     echo "Git Commit: \$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" >> native-libs/BUILD_INFO.txt;     echo "OS: ${CIRCE_SYS_LOWER}" >> native-libs/BUILD_INFO.txt;     echo "Arch: ${CIRCE_ARCH}" >> native-libs/BUILD_INFO.txt;     echo "Jar: circe-cli.jar" >> native-libs/BUILD_INFO.txt;     echo "Native Library: libcirce-native.so" >> native-libs/BUILD_INFO.txt;     echo '[circe-native] Done (native lib: ${CIRCE_NATIVE_SO})'"
  DEPENDS ${CMAKE_CURRENT_LIST_DIR}/graalvm-config/reflect-config.json ${CMAKE_CURRENT_LIST_DIR}/graalvm-config/resource-config.json
  WORKING_DIRECTORY ${CMAKE_CURRENT_LIST_DIR}
  COMMENT "Building Circe native shared library via CMake (GraalVM native-image)"
  VERBATIM
)
add_custom_target(circe_native DEPENDS ${CIRCE_NATIVE_SO} ${CIRCE_NATIVE_BUILD_STAMP})


# circe extension configured; source renamed from quack_extension.cpp to circe_extension.cpp
# Extension from this repo (renamed to circe)
duckdb_extension_load(circe
    SOURCE_DIR ${CMAKE_CURRENT_LIST_DIR}
    LOAD_TESTS
)

# Add include directory for consolidated Circe native headers
if (TARGET circe_extension)
  target_include_directories(circe_extension PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/include/circe_native)
endif()
if (TARGET circe_loadable_extension)
  target_include_directories(circe_loadable_extension PRIVATE ${CMAKE_CURRENT_LIST_DIR}/src/include/circe_native)
endif()


# Ensure circe targets depend on circe_native if it exists
if (TARGET circe_native AND TARGET circe_extension)
  add_dependencies(circe_extension circe_native)
endif()
if (TARGET circe_native AND TARGET circe_loadable_extension)
  add_dependencies(circe_loadable_extension circe_native)
endif()

# Any extra extensions that should be built
# e.g.: duckdb_extension_load(json)
