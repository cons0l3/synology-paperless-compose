
#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# Reindex Postgres objects for paperless-ngx (or any app) while filtering out
# tiny tables and rarely-used indexes.
#
# Default behavior:
#   - REINDEX INDEX CONCURRENTLY on frequently-used, non-tiny indexes in 'public'
#   - Skips small tables and small indexes
#
# Customize via env vars or CLI flags.
###############################################################################

# ---- Defaults (override with flags or environment) --------------------------
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-paperless}"
PGDATABASE="${PGDATABASE:-paperless}"
PGPASSWORD="${PGPASSWORD:-}"

# If connecting to a Dockerized Postgres, set the container name here:
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-}"   # e.g., paperless-db-1 ; leave empty for local psql

# Filters
MIN_IDX_SCANS="${MIN_IDX_SCANS:-10000}"        # minimum idx_scan in pg_stat_all_indexes
MIN_TABLE_SIZE_MB="${MIN_TABLE_SIZE_MB:-100}"   # minimum table total size (MB)
MIN_INDEX_SIZE_MB="${MIN_INDEX_SIZE_MB:-50}"    # minimum index size (MB)

SCHEMAS="${SCHEMAS:-public}"                    # comma-separated schema names

# Reindex scope: index|table
REINDEX_SCOPE="${REINDEX_SCOPE:-index}"

# Use REINDEX CONCURRENTLY? (true|false)  -> requires PG >= 120000
REINDEX_CONCURRENTLY="${REINDEX_CONCURRENTLY:-true}"

# Dry run? (true|false)
DRY_RUN="${DRY_RUN:-false}"

# Logging
LOG_FILE="${LOG_FILE:-./log/pg_reindex_filtered.log}"

# ---- Helpers ----------------------------------------------------------------
usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Options:
  --host HOST                (default: $PGHOST)
  --port PORT                (default: $PGPORT)
  --user USER                (default: $PGUSER)
  --db DBNAME                (default: $PGDATABASE)
  --password PASSWORD        (default: env PGPASSWORD)
  --container NAME           Docker container name for Postgres
  --schemas LIST             Comma-separated schemas (default: $SCHEMAS)
  --min-idx-scans N          (default: $MIN_IDX_SCANS)
  --min-table-size-mb MB     (default: $MIN_TABLE_SIZE_MB)
  --min-index-size-mb MB     (default: $MIN_INDEX_SIZE_MB)
  --scope index|table        (default: $REINDEX_SCOPE)
  --concurrently true|false  (default: $REINDEX_CONCURRENTLY)
  --dry-run true|false       (default: $DRY_RUN)
  --log-file PATH            (default: $LOG_FILE)
  -h, --help

Examples:
  # Safe defaults (index-level, concurrently):
  $(basename "$0") --container paperless-db-1

  # Table-level rebuilds during maintenance window:
  $(basename "$0") --scope table --concurrently false --min-idx-scans 5000

  # Preview only:
  $(basename "$0") --dry-run true
USAGE
}

# Simple logger
log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

# Run psql either locally or inside docker
run_psql() {
  local psql_args=("$@")
  if [[ -n "$POSTGRES_CONTAINER" ]]; then
    docker exec -e "PGPASSWORD=$PGPASSWORD" -i "$POSTGRES_CONTAINER" \
      psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "${psql_args[@]}"
  else
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" "${psql_args[@]}"
  fi
}

# Get server version number (e.g., 160002) for comparisons
get_server_version_num() {
  run_psql -At -c "SHOW server_version_num;" | tr -d '[:space:]'
}

# ---- CLI parsing ------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) PGHOST="$2"; shift 2;;
    --port) PGPORT="$2"; shift 2;;
    --user) PGUSER="$2"; shift 2;;
    --db) PGDATABASE="$2"; shift 2;;
    --password) PGPASSWORD="$2"; shift 2;;
    --container) POSTGRES_CONTAINER="$2"; shift 2;;
    --schemas) SCHEMAS="$2"; shift 2;;
    --min-idx-scans) MIN_IDX_SCANS="$2"; shift 2;;
    --min-table-size-mb) MIN_TABLE_SIZE_MB="$2"; shift 2;;
    --min-index-size-mb) MIN_INDEX_SIZE_MB="$2"; shift 2;;
    --scope) REINDEX_SCOPE="$2"; shift 2;;
    --concurrently) REINDEX_CONCURRENTLY="$2"; shift 2;;
    --dry-run) DRY_RUN="$2"; shift 2;;
    --log-file) LOG_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) log "Unknown option: $1"; usage; exit 1;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"

log "Starting filtered reindex: host=$PGHOST port=$PGPORT db=$PGDATABASE user=$PGUSER"
log "schemas=$SCHEMAS scope=$REINDEX_SCOPE concurrently=$REINDEX_CONCURRENTLY dry_run=$DRY_RUN"
log "filters: min_idx_scans=$MIN_IDX_SCANS min_table_size_mb=$MIN_TABLE_SIZE_MB min_index_size_mb=$MIN_INDEX_SIZE_MB"

# ---- Safety checks ----------------------------------------------------------
ver_num="$(get_server_version_num || echo 0)"
if [[ "$REINDEX_CONCURRENTLY" == "true" && "$ver_num" -lt 120000 ]]; then
  log "ERROR: server_version_num=$ver_num (< 120000). REINDEX CONCURRENTLY requires PostgreSQL >= 12."
  log "       Rerun with --concurrently false"
  exit 2
fi

# ---- SQL builders -----------------------------------------------------------
# We select candidate indexes meeting filters, then either:
#   - REINDEX INDEX (one by one), or
#   - REINDEX TABLE (distinct tables of candidates)
#
# Filters:
#   - s.idx_scan >= :min_scans
#   - pg_total_relation_size(table) >= :min_table_bytes
#   - pg_relation_size(index) >= :min_index_bytes
#   - schema in provided list
#
# NOTE: We prefer CONCURRENTLY to minimize locking if supported.
concurrently_keyword=""
if [[ "$REINDEX_CONCURRENTLY" == "true" ]]; then
  concurrently_keyword=" CONCURRENTLY"
fi

read -r -d '' SQL_INDEX_CANDIDATES <<'SQL'
WITH candidates AS (
  SELECT
      n.nspname                         AS schemaname,
      t.relname                         AS tablename,
      i.relname                         AS indexname,
      s.idx_scan                        AS idx_scan,
      pg_total_relation_size(t.oid)     AS table_bytes,
      pg_relation_size(i.oid)           AS index_bytes
  FROM pg_stat_all_indexes AS s
  JOIN pg_class AS i ON i.oid = s.indexrelid
  JOIN pg_class AS t ON t.oid = s.relid
  JOIN pg_namespace AS n ON n.oid = t.relnamespace
  WHERE n.nspname = ANY (regexp_split_to_array(:schemas, ','))
    AND s.idx_scan >= :min_scans::bigint
    AND pg_total_relation_size(t.oid) >= :min_table_bytes::bigint
    AND pg_relation_size(i.oid) >= :min_index_bytes::bigint
)
SELECT schemaname, tablename, indexname, idx_scan, table_bytes, index_bytes
FROM candidates
ORDER BY idx_scan DESC, index_bytes DESC;
SQL

# Build REINDEX commands with psql's \gexec to execute server-side.
# Use %I to quote identifiers safely.
if [[ "$REINDEX_SCOPE" == "index" ]]; then
  read -r -d '' SQL_REINDEX <<SQL
WITH c AS (
  ${SQL_INDEX_CANDIDATES}
)
SELECT format('REINDEX INDEX${concurrently_keyword} %I.%I;', schemaname, indexname)
FROM c
ORDER BY idx_scan DESC, index_bytes DESC
\gexec
SQL
elif [[ "$REINDEX_SCOPE" == "table" ]]; then
  read -r -d '' SQL_REINDEX <<SQL
WITH c AS (
  ${SQL_INDEX_CANDIDATES}
),
dedup AS (
  SELECT DISTINCT schemaname, tablename
  FROM c
)
SELECT format('REINDEX TABLE${concurrently_keyword} %I.%I;', schemaname, tablename)
FROM dedup
ORDER BY schemaname, tablename
\gexec
SQL
else
  log "ERROR: --scope must be 'index' or 'table' (got: $REINDEX_SCOPE)"
  exit 3
fi

# ---- Dry-run (preview) ------------------------------------------------------
read -r -d '' SQL_PREVIEW <<'SQL'
WITH c AS (
  SELECT
      n.nspname                         AS schemaname,
      t.relname                         AS tablename,
      i.relname                         AS indexname,
      s.idx_scan                        AS idx_scan,
      pg_size_pretty(pg_total_relation_size(t.oid)) AS table_size,
      pg_size_pretty(pg_relation_size(i.oid))       AS index_size
  FROM pg_stat_all_indexes AS s
  JOIN pg_class AS i ON i.oid = s.indexrelid
  JOIN pg_class AS t ON t.oid = s.relid
  JOIN pg_namespace AS n ON n.oid = t.relnamespace
  WHERE n.nspname = ANY (regexp_split_to_array(:schemas, ','))
    AND s.idx_scan >= :min_scans::bigint
    AND pg_total_relation_size(t.oid) >= :min_table_bytes::bigint
    AND pg_relation_size(i.oid) >= :min_index_bytes::bigint
)
SELECT schemaname, tablename, indexname, idx_scan, table_size, index_size
FROM c
ORDER BY idx_scan DESC, index_size DESC;
SQL

# ---- Execute ---------------------------------------------------------------
log "Preview of candidates (schema, table, index, idx_scan, table_size, index_size):"
run_psql -v "schemas=$SCHEMAS" \
         -v "min_scans=$MIN_IDX_SCANS" \
         -v "min_table_bytes=$((MIN_TABLE_SIZE_MB * 1024 * 1024))" \
         -v "min_index_bytes=$((MIN_INDEX_SIZE_MB * 1024 * 1024))" \
         -P pager=off -F $'\t' -c "$SQL_PREVIEW" | tee -a "$LOG_FILE"

if [[ "$DRY_RUN" == "true" ]]; then
  log "Dry-run enabled: showing generated REINDEX statements only."
  run_psql -v "schemas=$SCHEMAS" \
           -v "min_scans=$MIN_IDX_SCANS" \
           -v "min_table_bytes=$((MIN_TABLE_SIZE_MB * 1024 * 1024))" \
           -v "min_index_bytes=$((MIN_INDEX_SIZE_MB * 1024 * 1024))" \
           -P pager=off -c "${SQL_REINDEX//$'\\gexec'/}"
  log "Done (no changes applied)."
  exit 0
fi

log "Executing REINDEX statements..."
run_psql -v "schemas=$SCHEMAS" \
         -v "min_scans=$MIN_IDX_SCANS" \
         -v "min_table_bytes=$((MIN_TABLE_SIZE_MB * 1024 * 1024))" \
         -v "min_index_bytes=$((MIN_INDEX_SIZE_MB * 1024 * 1024))" \
         -P pager=off -c "$SQL_REINDEX" | tee -a "$LOG_FILE"

log "Reindex complete."

