#!/usr/bin/env bash
# Shared helpers for backup.sh. Sourced, never executed directly.

set -Eeuo pipefail
umask 077   # dumps, archives and logs are readable by the backup user only

# cron runs with PATH=/usr/bin:/bin — the AWS CLI v2 installs to /usr/local/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

BACKUP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${BACKUP_ROOT}/config/backup.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "FATAL: ${ENV_FILE} not found. Copy config/backup.env.example to config/backup.env and fill it in." >&2
  exit 1
fi
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

: "${AWS_ACCESS_KEY_ID:?missing in backup.env}"
: "${AWS_SECRET_ACCESS_KEY:?missing in backup.env}"
: "${S3_BUCKET:?missing in backup.env}"
: "${PG_CONTAINER:?missing in backup.env}"
: "${PG_USER:?missing in backup.env}"

AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
S3_ENDPOINT_URL="${S3_ENDPOINT_URL:-}"
S3_PREFIX="${S3_PREFIX:-vertical-platform/postgres}"
S3_PREFIX="${S3_PREFIX%/}"
BACKUP_NAME="${BACKUP_NAME:-vertical}"
RETENTION_DAYS="${RETENTION_DAYS:-3}"
REQUIRED_DATABASES="${REQUIRED_DATABASES:-}"
EXCLUDE_DATABASES="${EXCLUDE_DATABASES:-}"
BACKUP_TMP_DIR="${BACKUP_TMP_DIR:-/opt/vertical/backup_tmp}"
LOG_DIR="${LOG_DIR:-${BACKUP_ROOT}/logs}"
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"
LOCK_FILE="${LOCK_FILE:-${BACKUP_TMP_DIR}/backup.lock}"
UPLOAD_RETRIES="${UPLOAD_RETRIES:-3}"

[[ "$RETENTION_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "FATAL: RETENTION_DAYS must be a positive integer (got '${RETENTION_DAYS}')" >&2; exit 1; }
[[ "$BACKUP_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "FATAL: BACKUP_NAME may only contain letters, digits, . _ -" >&2; exit 1; }

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
# A blank `output =` in ~/.aws/config makes every aws call fail with "Unknown output type".
export AWS_DEFAULT_OUTPUT="${AWS_DEFAULT_OUTPUT:-json}"
# AWS CLI >= 2.23 sends extra integrity checksums by default, which some S3-compatible
# stores (Cloudflare R2, DigitalOcean Spaces) reject. Only send them when S3 requires it.
export AWS_REQUEST_CHECKSUM_CALCULATION="${AWS_REQUEST_CHECKSUM_CALCULATION:-when_required}"
export AWS_RESPONSE_CHECKSUM_VALIDATION="${AWS_RESPONSE_CHECKSUM_VALIDATION:-when_required}"

mkdir -p "$LOG_DIR" "$BACKUP_TMP_DIR"

LOG_FILE="${LOG_DIR}/$(basename "$0" .sh)_$(date +%F).log"

# Writes to the daily log file; also to the terminal when run by hand. Under cron
# stderr is not a TTY, so cron.log only catches output that bypasses log().
log() {
  local level="$1"; shift
  local line
  line="$(printf '%s [%s] %s' "$(date '+%F %T')" "$level" "$*")"
  printf '%s\n' "$line" >> "$LOG_FILE"
  [[ -t 2 ]] && printf '%s\n' "$line" >&2
  return 0
}

die() {
  log ERROR "$*"
  exit 1
}

# Best-effort notifications — a broken alert channel must never mask the real error.
alert() {
  local subject="$1" body="$2"
  if [[ -n "${ALERT_WEBHOOK_URL:-}" ]]; then
    local payload
    payload="$(printf '%s\n%s' "$subject" "$body" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk '{printf "%s\\n", $0}')"
    curl -fsS -m 15 -H 'Content-Type: application/json' \
      -d "{\"text\":\"${payload}\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 \
      || log WARN "Alert webhook delivery failed"
  fi
  if [[ -n "${ALERT_EMAIL:-}" ]] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL" || log WARN "Alert email delivery failed"
  fi
  return 0
}

# Pings an external dead-man's-switch monitor (healthchecks.io, Uptime Kuma push,
# Better Stack heartbeat...). It alerts when the ping STOPS arriving — the only
# way to catch "cron never ran" or "the server is down", which this script can't.
heartbeat() {
  [[ -n "${HEARTBEAT_URL:-}" ]] || return 0
  curl -fsS -m 15 --retry 3 "$HEARTBEAT_URL" >/dev/null 2>&1 \
    || log WARN "Heartbeat ping failed"
  return 0
}

require_cmds() {
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  (( ${#missing[@]} == 0 )) || die "Missing required commands: ${missing[*]}"
}

# Serializes runs so a slow backup never overlaps a second (cron or manual) one.
acquire_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another backup run is still holding ${LOCK_FILE}"
}

# Runs a command inside the postgres container. The password is read from the
# container's own POSTGRES_PASSWORD, so it never appears on the host — not in a
# file, not in `ps`, not in these logs.
pg_exec() {
  docker exec "$PG_CONTAINER" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec "$@"' sh "$@"
}

# Same as pg_exec, with stdin attached (for streaming a file into the container).
pg_exec_stdin() {
  docker exec -i "$PG_CONTAINER" sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" exec "$@"' sh "$@"
}

aws_s3() {
  aws ${S3_ENDPOINT_URL:+--endpoint-url "$S3_ENDPOINT_URL"} "$@"
}

file_size() {
  stat -c %s "$1"
}

# Deletes this script's own log files older than LOG_RETENTION_DAYS, and trims
# cron.log so it can't grow forever.
prune_logs() {
  find "$LOG_DIR" -maxdepth 1 -type f -name "$(basename "$0" .sh)_*.log" \
    -mtime +"$LOG_RETENTION_DAYS" -delete 2>/dev/null || true
  local cron_log="${LOG_DIR}/cron.log"
  if [[ -f "$cron_log" ]] && (( $(file_size "$cron_log") > 10485760 )); then
    tail -n 2000 "$cron_log" > "${cron_log}.tmp" && mv "${cron_log}.tmp" "$cron_log"
  fi
}
