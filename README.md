# Quack DuckDB Extension (Circe Integrated)

This repository is based on the DuckDB extension template and adds a GraalVM native build of the OHDSI Circe cohort expression -> SQL generator.

## Contents
- DuckDB extension source: `src/`, config in `extension_config.cmake`
- Circe Java sources + Graal configs: `circe-be/`
- Reflection config: `graalvm-config/reflect-config.json`
- Resource config:   `graalvm-config/resource-config.json`
- Built native lib output: `circe-be/native-libs/<os-arch>/libcirce-native.so`
- Loadable DuckDB extension artifact: `build/release/extension/quack/quack.duckdb_extension`

## Prerequisites
Install (and on PATH):
- C/C++ toolchain (gcc/clang)
- CMake, make (or ninja + ccache optional)
- GraalVM JDK (Java 21+) with `native-image` component (gu install native-image)
- Maven

Optional: VCPKG if adding external C/C++ deps (template supports it but current code does not require external packages).

## Build Steps
Minimal full build (native library + DuckDB extension):
```bash
make                # builds everything: circe-native + DuckDB extension in ./build/release
```

Or step by step:
```bash
make circe-native   # builds Circe jar & native shared library using existing reflect/resource configs
make release        # builds DuckDB + quack extension (loadable + statically linked) in ./build/release
```

Alternative explicit commands:
```bash
make all            # equivalent to: make (default target)
```

Faster rebuild after editing ONLY Circe Java:
```bash
make circe-native
make release        # rebuild the extension
```

Use ninja for faster C++ rebuilds:
```bash
GEN=ninja make
```

## Running
A DuckDB CLI matching the extension build version (currently v1.3.2) is required. Place the downloaded binary under `tools/duckdb/duckdb` (already present here).

Interactive run with extension preloaded (static):
```bash
./build/release/duckdb
```

Load the produced loadable extension explicitly (unsigned):
```bash
./tools/duckdb/duckdb -unsigned <<'SQL'
load './build/release/extension/quack/quack.duckdb_extension';
select quack('Jane');
SQL
```

Circe function example (JSON -> SQL or error comment):
```sql
select substr(circe_json_to_sql('{"foo":"bar"}','{}'),1,400);
```

## Modifying Reflection / Resources
Edit the JSON files under `graalvm-config/` (moved out of `circe-be/` to minimize vendored tree changes) and rebuild with `make circe-native`. These are NOT auto-generated (kept static for reproducibility).

## Rebuilding After Java Changes
1. Modify Java under `circe-be/src/main/java/...`
2. Run `make circe-native`
3. Rebuild or reuse existing DuckDB build (`make` if needed)

## Troubleshooting
- Version mismatch loading extension: ensure CLI is DuckDB v1.3.2 (check `./tools/duckdb/duckdb -version`).
- Empty or truncated error: current Java entrypoint returns full stack inside a SQL comment `/* circe error: ... */`. Use `substr(...)` or `length(...)` to inspect.
- Native lib not picked up: confirm path `circe-be/native-libs/<os>-<arch>/libcirce-native.so` exists before CMake build; `extension_config.cmake` adds dependency.
- Rebuild not reflected: delete `circe-be/target` if Maven cache confusion, then `make circe-native`.

## Tests
Run all SQL logic tests (including any added for Circe):
```bash
make test
```

## Circe JSON Usage
The function signature is:
```
circe_json_to_sql(expression_json VARCHAR, options_json VARCHAR) -> VARCHAR
```
- `expression_json`: CohortExpression JSON (OHDSI Circe schema)
- `options_json`: JSON for `CohortExpressionQueryBuilder.BuildExpressionQueryOptions` (may be empty `{}`)

Minimal valid example (produces a trivial SQL skeleton):
```sql
SELECT substr(circe_json_to_sql('{"PrimaryCriteria":{"CriteriaList":[],"ObservationWindow":{"PriorDays":0,"PostDays":0},"PrimaryCriteriaLimit":{"Type":"First"}},"ExpressionLimit":{"Type":"All"},"InclusionRules":[],"ConceptSets":[]}','{}'),1,400) AS snippet;
```

Common option fields (include only those you need):
```json
{
  "cdmSchema": "cdm",
  "targetTable": "cohort",
  "resultSchema": "results",
  "generateStats": true,
  "vocabDatabaseSchema": "vocab"
}
```
(Any missing optional fields default to Circe's internal defaults.)

### Supplying Large JSON Safely
To avoid shell quoting hassles, either:
1. Use a parameter table: `CREATE TABLE tmp(expr TEXT); INSERT INTO tmp VALUES('<json>'); SELECT circe_json_to_sql(expr,'{}') FROM tmp;`
2. Or read from an external file in your client code and bind as a parameter (recommended in applications).

## SQL Rendering and Translation Functions

This extension also provides SQL template rendering and dialect translation functions using the OHDSI SQLRender library:

### circe_sql_render
Renders SQL templates with parameter substitution:
```sql
SELECT circe_sql_render(sql_template VARCHAR, parameters_json VARCHAR) -> VARCHAR
```

Example:
```sql
SELECT circe_sql_render(
  'SELECT * FROM @schema.@table WHERE age >= @min_age AND status = @status;',
  '{"schema": "cdm", "table": "patients", "min_age": "18", "status": "active"}'
);
-- Returns: SELECT * FROM cdm.patients WHERE age >= 18 AND status = active;
```

### circe_sql_translate
Translates SQL from one dialect to another:
```sql
SELECT circe_sql_translate(sql VARCHAR, target_dialect VARCHAR) -> VARCHAR
```

Supported dialects: `sql server` (default), `postgresql`, `oracle`, `redshift`, `netezza`, `impala`, `bigquery`, `spark`, `snowflake`

Example:
```sql
SELECT circe_sql_translate(
  'SELECT TOP 10 patient_id, ISNULL(name, ''Unknown'') FROM patients;',
  'postgresql'
);
-- Returns: SELECT  patient_id, COALESCE(name,'Unknown') FROM patients LIMIT 10;
```

### circe_sql_render_translate
Combines template rendering and dialect translation in one step:
```sql
SELECT circe_sql_render_translate(sql_template VARCHAR, target_dialect VARCHAR, parameters_json VARCHAR) -> VARCHAR
```

Example:
```sql
SELECT circe_sql_render_translate(
  'SELECT TOP @limit * FROM @schema.visits WHERE visit_date >= DATEADD(day, @days, GETDATE());',
  'postgresql',
  '{"limit": "5", "schema": "omop", "days": "-30"}'
);
-- Returns: SELECT  * FROM omop.visits WHERE visit_date >= (CURRENT_DATE + -30*INTERVAL'1 day') LIMIT 5;
```

### Parameter Handling
- Parameters are specified with `@parameter_name` syntax in SQL templates
- Parameters JSON should be a flat object with string values: `{"param": "value"}`
- Missing parameters are left as-is in the rendered SQL
- Invalid JSON gracefully falls back to rendering without parameters

## Debugging Errors
On failure the function returns a multi-line SQL comment starting with `/* circe error:` followed by the full Java stack trace (added in the native entrypoint). Example detection:
```sql
SELECT CASE WHEN result LIKE '/* circe error:%' THEN 'ERROR' ELSE 'OK' END status FROM (
  SELECT circe_json_to_sql('{"foo":"bar"}','{}') AS result
);
```
Capture entire trace (avoid display truncation):
```sql
CREATE TABLE dbg AS SELECT circe_json_to_sql('{"foo":"bar"}','{}') AS x;
.copy (SELECT x FROM dbg) TO 'circe_error.txt' (HEADER FALSE);
```
A `NullPointerException` at `getPrimaryEventsQuery` usually means the `PrimaryCriteria` block is missing or incomplete.

## Maintaining Reflection/Resources
To modify reflection or resource configurations, edit the JSON files under `graalvm-config/` directly, then rebuild:
```bash
make circe-native
```
If you add new Circe model classes (e.g., upgrading Circe) ensure they are listed in `reflect-config.json` with the appropriate `allDeclared*` flags.

## Limitations / Roadmap
- Only cohort SQL generation is exposed (no concept set optimization / negative controls generation yet).
- No streaming / chunked output (entire SQL returned as one string).
- File IO helper function available: `circe_json_file_to_sql(path, options)` to safely read large JSON from disk.
- Reflection config is intentionally broad; future work could prune unreachable classes for smaller images.

## Directory Highlights
- `demo_extension.sql` example script for manual testing
- `tools/duckdb/duckdb` DuckDB CLI binary used for unsigned loading

## License
See `LICENSE` (same as template).

---
Short reference:
```bash
make               # builds everything
./tools/duckdb/duckdb -unsigned -init demo_extension.sql
```
