PROJ_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))

# Default target
.DEFAULT_GOAL := all

# Configuration of extension
EXT_NAME=quack
EXT_CONFIG=${PROJ_DIR}extension_config.cmake

CIRCE_DIR:=circe-be
CIRCE_TARGET:=$(CIRCE_DIR)/target
CIRCE_JAR:=$(CIRCE_TARGET)/circe-cli.jar
# Updated to allow root-level override
ROOT_GRAAL_CONF_DIR:=${PROJ_DIR}graalvm-config
CIRCE_REFLECT:=$(ROOT_GRAAL_CONF_DIR)/reflect-config.json
CIRCE_RESOURCES:=$(ROOT_GRAAL_CONF_DIR)/resource-config.json
CIRCE_NATIVE_SO:=$(CIRCE_DIR)/native-libs/$(shell uname -s | tr A-Z a-z)-$(shell uname -m)/libcirce-native.so
CIRCE_INIT_PKGS:=org.ohdsi.circe,com.fasterxml.jackson

RESOURCE_JSON := { "resources": [ {"pattern": ".*cohortdefinition/sql/.*\\.sql"}, {"pattern": ".*vocabulary/sql/.*\\.sql"}, {"pattern": ".*sql/.*\\.sql"}, {"pattern": ".*templates/.*"}, {"pattern": ".*ftl"} ] }

.PHONY: circe-native
circe-native:
	@echo "[circe-native] Building Circe native library (static reflection config)"
	@if ! command -v native-image >/dev/null 2>&1; then echo "native-image not found" >&2; exit 1; fi
	@if ! command -v mvn >/dev/null 2>&1; then echo "maven not found" >&2; exit 1; fi
	@mkdir -p $(ROOT_GRAAL_CONF_DIR)
	@(cd $(CIRCE_DIR) && mvn -q -DskipTests -Dmaven.test.skip=true -Djacoco.skip=true -Dskip.unit.tests=true clean package dependency:build-classpath -DincludeScope=runtime -Dmdep.outputFile=target/classpath.txt)
	@cp -f $(CIRCE_TARGET)/circe-*.jar $(CIRCE_DIR)/target/circe-cli.jar
	@echo "[circe-native] Using reflect-config.json and resource-config.json from root graalvm-config/"
	@echo "[circe-native] Compiling bootstrap main" && mkdir -p $(CIRCE_TARGET)/bootstrap && echo 'public class CirceBootstrapMain { public static void main(String[] a){ System.out.println("Circe native image bootstrap"); } }' > $(CIRCE_TARGET)/bootstrap/CirceBootstrapMain.java && javac -cp $(CIRCE_DIR)/target/circe-cli.jar -d $(CIRCE_TARGET)/bootstrap $(CIRCE_TARGET)/bootstrap/CirceBootstrapMain.java
	@echo "[circe-native] Running native-image" && (cd $(CIRCE_DIR) && CP=`tr -d '\r' < target/classpath.txt`; native-image --no-fallback --shared --enable-all-security-services -H:+ReportExceptionStackTraces -J-Xss8m -J-Xmx2g -H:ConfigurationFileDirectories=$(ROOT_GRAAL_CONF_DIR) --initialize-at-build-time=$(CIRCE_INIT_PKGS) -H:Name=circe-native -cp target/circe-cli.jar:target/bootstrap:$$CP -H:Class=CirceBootstrapMain )
	@mkdir -p $(dir $(CIRCE_NATIVE_SO))
	@mv -f $(CIRCE_DIR)/circe-native.so $(CIRCE_NATIVE_SO)
	@cp -f $(CIRCE_DIR)/target/circe-cli.jar $(dir $(CIRCE_NATIVE_SO))
	@echo "Build Timestamp: $$(date -u +'%Y-%m-%dT%H:%M:%SZ')" > $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "Git Commit: $$(git -C $(CIRCE_DIR) rev-parse --short HEAD 2>/dev/null || echo unknown)" >> $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "OS: $$(uname -s)" >> $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "Arch: $$(uname -m)" >> $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "Jar: circe-cli.jar" >> $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "Native Library: $$(basename $(CIRCE_NATIVE_SO))" >> $(CIRCE_DIR)/native-libs/BUILD_INFO.txt
	@echo "Done (native lib: $(CIRCE_NATIVE_SO))"

# Include the Makefile from extension-ci-tools
include extension-ci-tools/makefiles/duckdb_extension.Makefile