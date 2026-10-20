#!/usr/bin/env bash
# Daily full PostgreSQL backup -> S3-compatible storage (DigitalOcean Spaces / AWS S3)
#
# One run:
#   1. Pre-flight: tools, container health, bucket access, free disk space.
#   2. Full backup of EVERY database in the cluster (platform DB, tenant template
#      DB and every tenant_<id> DB created at signup) with pg_dump custom format,
#      plus the cluster globals (roles/grants) with pg_dumpall --globals-only.
#   3. Verify each dump is a readable archive and write SHA256SUMS + MANIFEST.
#   4. Pack everything into ONE archive and upload it:
#        s3://<bucket>/<prefix>/<BACKUP_NAME>_<YYYY-MM-DD>_<HHMMSS>.tar
#      A single object is atomic — it either exists complete or not at all.
#   5. Verify the uploaded size matches.
#   6. Only after 1-5 succeed: keep the newest RETENTION_DAYS days of backups and
#      delete older ones. With RETENTION_DAYS=3, day 4's run deletes day 1's backup.
#      A failed run never deletes anything, so old backups are never lost because
#      a new one broke.
#
# Usage: backup.sh [--dry-run]
#   --dry-run  runs every pre-flight check and shows what retention would delete,
#              but dumps, uploads and deletes nothing.

set -Eeuo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${DIR}/../lib/common.sh"

DRY_RUN=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "Usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

STAMP="$(date +%F_%H%M%S)"
RUN_DIR="${BACKUP_TMP_DIR}/run_${STAMP}"
DATA_DIR="${RUN_DIR}/${BACKUP_NAME}_${STAMP}"
ARCHIVE="${RUN_DIR}/${BACKUP_NAME}_${STAMP}.tar"
S3_KEY="${S3_PREFIX}/${BACKUP_NAME}_${STAMP}.tar"
STARTED_AT="$(date +%s)"

on_err() {
  log ERROR "Command failed (exit $1) at line $2: $3"
}

on_exit() {
  local rc=$?
  [[ -n "${RUN_DIR:-}" && -d "$RUN_DIR" ]] && rm -rf "$RUN_DIR"
  if (( rc != 0 )); then
    log ERROR "=== backup.sh FAILED (exit ${rc}) — no old backups were deleted ==="
    alert "[vertical-backup] FAILED on $(hostname)" \
      "Backup ${BACKUP_NAME}_${STAMP} failed (exit ${rc}). Old backups were kept. See ${LOG_FILE}"$'\n\n'"$(tail -n 20 "$LOG_FILE" 2>/dev/null)"
  fi
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT

# ── Retention ────────────────────────────────────────────────────────────
# Reads backup object keys on stdin; prints the keys to delete: everything
# outside the newest <keep_days> distinct dates. Keys that don't match our exact
# naming pattern are never printed, so nothing else in the bucket is touched.
select_expired_keys() {
  local keep_days="$1" prefix="${S3_PREFIX}/${BACKUP_NAME}_" key rest d i
  local -a keys=() dates=()
  local -A kept=()
  while IFS= read -r key; do
    [[ "$key" == "$prefix"* ]] || continue
    rest="${key#"$prefix"}"
    [[ "$rest" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})_[0-9]{6}\.tar$ ]] || continue
    keys+=("$key"); dates+=("${BASH_REMATCH[1]}")
  done
  (( ${#keys[@]} > 0 )) || return 0
  while IFS= read -r d; do kept["$d"]=1; done \
    < <(printf '%s\n' "${dates[@]}" | sort -ur | head -n "$keep_days")
  for i in "${!keys[@]}"; do
    [[ -n "${kept[${dates[$i]}]:-}" ]] || printf '%s\n' "${keys[$i]}"
  done
}

list_backup_keys() {
  local out
  out="$(aws_s3 s3api list-objects-v2 --bucket "$S3_BUCKET" \
           --prefix "${S3_PREFIX}/${BACKUP_NAME}_" \
           --query 'Contents[].Key' --output text)" \
    || die "Could not list s3://${S3_BUCKET}/${S3_PREFIX}/ — retention skipped"
  printf '%s\n' "$out" | tr '\t' '\n' | sed '/^None$/d; /^$/d' | sort
}

apply_retention() {
  local keys expired key count=0
  keys="$(list_backup_keys)"

  if (( DRY_RUN == 0 )); then
    # Never prune unless the backup we just made is visible in the bucket.
    grep -qxF "$S3_KEY" <<< "$keys" \
      || die "New backup ${S3_KEY} not found in bucket listing — refusing to delete old backups"
  fi

  expired="$(select_expired_keys "$RETENTION_DAYS" <<< "$keys")"
  log INFO "Objects under ${S3_PREFIX}/${BACKUP_NAME}_*: $(grep -c . <<< "$keys" || true); keeping newest ${RETENTION_DAYS} day(s)"

  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    if (( DRY_RUN == 1 )); then
      log INFO "[dry-run] would delete expired backup: ${key}"
    else
      log INFO "Deleting expired backup: ${key}"
      aws_s3 s3 rm "s3://${S3_BUCKET}/${key}" --only-show-errors \
        || log WARN "Failed to delete ${key} — will retry on the next run"
    fi
    count=$((count + 1))
  done <<< "$expired"
  log INFO "Retention: ${count} expired backup(s) $( (( DRY_RUN == 1 )) && echo 'would be ' )removed"
}

# ── Pre-flight ───────────────────────────────────────────────────────────
log INFO "=== backup.sh starting (stamp=${STAMP}, dry_run=${DRY_RUN}, retention=${RETENTION_DAYS}d) ==="
require_cmds docker aws flock sha256sum tar gzip awk stat df find curl
acquire_lock

# Clean staging left behind by a run that was killed (power loss, OOM, SIGKILL)
# before its EXIT trap could run. Safe: we hold the lock, so no other run is active.
find "$BACKUP_TMP_DIR" -mindepth 1 -maxdepth 1 -type d -name 'run_*' -exec rm -rf {} + 2>/dev/null || true
prune_logs

[[ "$(docker inspect -f '{{.State.Running}}' "$PG_CONTAINER" 2>/dev/null)" == "true" ]] \
  || die "Container ${PG_CONTAINER} is not running"
pg_exec pg_isready -q -U "$PG_USER" -d postgres \
  || die "PostgreSQL in ${PG_CONTAINER} is not accepting connections"

aws_s3 s3api head-bucket --bucket "$S3_BUCKET" >/dev/null \
  || die "Cannot access bucket ${S3_BUCKET} (check keys, endpoint and bucket name)"

mapfile -t ALL_DBS < <(pg_exec psql -U "$PG_USER" -d postgres -AtX -c \
  "SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY datname")
(( ${#ALL_DBS[@]} > 0 )) || die "Could not list databases in ${PG_CONTAINER}"

DATABASES=()
for db in "${ALL_DBS[@]}"; do
  [[ " ${EXCLUDE_DATABASES} " == *" ${db} "* ]] && { log INFO "Excluding database ${db}"; continue; }
  DATABASES+=("$db")
done

# Guard against pointing at the wrong container: the core DBs must be present.
for db in $REQUIRED_DATABASES; do
  [[ " ${DATABASES[*]} " == *" ${db} "* ]] || die "Required database '${db}' not found in ${PG_CONTAINER}"
done
log INFO "Databases to back up (${#DATABASES[@]}): ${DATABASES[*]}"

# A compressed dump is much smaller than the live data, but the dumps and the tar
# archive briefly co-exist on disk — require free space >= total database size.
DB_BYTES="$(pg_exec psql -U "$PG_USER" -d postgres -AtX -c \
  "SELECT COALESCE(sum(pg_database_size(datname)),0) FROM pg_database WHERE NOT datistemplate")"
FREE_BYTES="$(df -PB1 "$BACKUP_TMP_DIR" | awk 'NR==2 {print $4}')"
log INFO "Cluster size: $((DB_BYTES / 1048576)) MiB, free in ${BACKUP_TMP_DIR}: $((FREE_BYTES / 1048576)) MiB"
(( FREE_BYTES > DB_BYTES )) || die "Not enough free disk space in ${BACKUP_TMP_DIR}"

if (( DRY_RUN == 1 )); then
  log INFO "[dry-run] would upload to s3://${S3_BUCKET}/${S3_KEY}"
  apply_retention
  log INFO "=== dry run OK — all pre-flight checks passed ==="
  exit 0
fi

# ── Dump ─────────────────────────────────────────────────────────────────
mkdir -p "$DATA_DIR"

for db in "${DATABASES[@]}"; do
  out="${DATA_DIR}/${db}.dump"
  log INFO "Dumping ${db}"
  # Custom format (-Fc): compressed full backup of schema + data, restorable
  # with pg_restore (whole DB, or single tables). --lock-wait-timeout stops a
  # long-held table lock from hanging the backup forever.
  pg_exec pg_dump -U "$PG_USER" -d "$db" -Fc -Z 6 --lock-wait-timeout=300000 > "$out" \
    || die "pg_dump failed for ${db}"
  [[ -s "$out" ]] || die "pg_dump produced an empty file for ${db}"
  pg_exec_stdin pg_restore --list < "$out" > /dev/null \
    || die "Dump of ${db} is not a readable archive"
  log INFO "  ${db}: $(( $(file_size "$out") / 1024 )) KiB"
done

log INFO "Dumping cluster globals (roles, grants)"
pg_exec pg_dumpall -U "$PG_USER" --globals-only | gzip -6 > "${DATA_DIR}/globals.sql.gz" \
  || die "pg_dumpall --globals-only failed"
gzip -t "${DATA_DIR}/globals.sql.gz" || die "globals.sql.gz is corrupt"

PG_VERSION="$(pg_exec psql -U "$PG_USER" -d postgres -AtX -c 'SHOW server_version')"
{
  echo "backup:          ${BACKUP_NAME}_${STAMP}"
  echo "host:            $(hostname)"
  echo "container:       ${PG_CONTAINER}"
  echo "postgres:        ${PG_VERSION}"
  echo "created:         $(date -Is)"
  echo "databases:       ${DATABASES[*]}"
  echo "format:          pg_dump custom (-Fc) per database + globals.sql.gz"
} > "${DATA_DIR}/MANIFEST.txt"
( cd "$DATA_DIR" && sha256sum -- *.dump globals.sql.gz MANIFEST.txt > SHA256SUMS )

# ── Archive + upload ─────────────────────────────────────────────────────
tar -cf "$ARCHIVE" -C "$RUN_DIR" "$(basename "$DATA_DIR")"
rm -rf "$DATA_DIR"
ARCHIVE_SIZE="$(file_size "$ARCHIVE")"
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
log INFO "Archive ${ARCHIVE##*/}: $((ARCHIVE_SIZE / 1048576)) MiB, sha256=${ARCHIVE_SHA}"

uploaded=0
for attempt in $(seq 1 "$UPLOAD_RETRIES"); do
  log INFO "Uploading to s3://${S3_BUCKET}/${S3_KEY} (attempt ${attempt}/${UPLOAD_RETRIES})"
  if aws_s3 s3 cp "$ARCHIVE" "s3://${S3_BUCKET}/${S3_KEY}" --only-show-errors \
       --metadata "sha256=${ARCHIVE_SHA}"; then
    uploaded=1; break
  fi
  log WARN "Upload attempt ${attempt} failed"
  if (( attempt < UPLOAD_RETRIES )); then sleep $((attempt * 30)); fi
done
(( uploaded == 1 )) || die "Upload failed after ${UPLOAD_RETRIES} attempts"

REMOTE_SIZE="$(aws_s3 s3api head-object --bucket "$S3_BUCKET" --key "$S3_KEY" \
  --query ContentLength --output text)" || die "Uploaded object not found: ${S3_KEY}"
[[ "$REMOTE_SIZE" == "$ARCHIVE_SIZE" ]] \
  || die "Size mismatch after upload: local ${ARCHIVE_SIZE} bytes, remote ${REMOTE_SIZE} bytes"
log INFO "Upload verified (${REMOTE_SIZE} bytes)"

# ── Retention (only reached when everything above succeeded) ─────────────
apply_retention

ELAPSED=$(( $(date +%s) - STARTED_AT ))
log INFO "=== backup.sh completed in ${ELAPSED}s: s3://${S3_BUCKET}/${S3_KEY} ==="
heartbeat
