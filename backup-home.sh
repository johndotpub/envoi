#!/bin/bash
# SPDX-License-Identifier: Unlicense
# This is free and unencumbered software released into the public domain.
# For information, see <https://unlicense.org/>
# home-backup — backs up a live $HOME tree to a local or mounted disk, safely.
#
# WHAT YOU GET PER RUN
#   snapshots/YYYY-MM-DD/
#     home.tar.gz  — the whole tree minus live SQLite DBs and the exclusions,
#                    written in one streaming pass (tar | pigz)
#     db/          — consistent online snapshots of every live SQLite DB
#     members.txt  — member list captured during creation (integrity manifest)
#     META         — host, date, member count, archive size, DB count
#     backup-home.sh, backup-excludes.txt — the exact code and exclusions used
#     RESTORE.txt  — restore instructions
#     db_find.err  — paths find could not read, if any
#
# RESTORE (see RESTORE.txt inside each snapshot for the full version)
#   1. stop the service using these files
#   2. delete stale -wal/-shm/-journal sidecars next to each db/ file's target path
#   3. tar -xzf home.tar.gz -C /home/<user>
#   4. cp -a db/. /home/<user>/
#   5. chown, verify (PRAGMA quick_check), start the service
#
# EXIT CODES
#   0  success — or a deliberate skip (lock held, or today's snapshot already exists)
#      A skip is 0 on purpose: cron must not alarm when a second invocation races the first.
#   1  backup failed (see backup.log and $HOME/.backup-fatal)
#   2  usage error / wrong user for this host
#   129/130/143  SIGHUP/SIGINT/SIGTERM
#
# ENVIRONMENT
#   MIN_MEMBERS   (default 100)  archive must contain more than this many members
#   MIN_FREE_GB   (default 50)   abort if the destination is nearly full
#   (--dry-run reports what it would do; changes nothing)
#
# CONFIGURATION
#   Per-host settings come from a config file, not from editing the script.
#   Copy backup.conf.example to backup.conf next to this script and edit it,
#   or point ENVOI_CONF at any file, or set the same variables in the environment
#   (environment wins over the file). Environment variables:
#     ENVOI_DEST          (required) directory snapshots go into; free space is checked
#     ENVOI_HOME_DIR      tree to back up               (default: $HOME)
#     ENVOI_SENTINEL      path that must exist in every archive, e.g. .profile
#                         (unset = sentinel check disabled)
#     ENVOI_MOUNT         mount point that must be present (e.g. /mnt/backups);
#                         if set and absent, the run aborts instead of filling /
#     ENVOI_EXPECT_USER   refuse to run as any other user (e.g. root)
#     ENVOI_LABEL         label used in logs              (default: hostname)
#     ENVOI_EXTRA_EXCLUDES space-separated extra excludes for this host
#     ENVOI_EXCLUDES_FILE excludes file                (default: backup-excludes.txt next to this script)
#
# THREAT MODEL / PLATFORM NOTES
#   Written for Linux on a disk that may be a 9p/drvfs Windows mount (e.g. /mnt/d).
#   There, ownership and permissions are cosmetic — do not rely on them. On native
#   Linux they hold, and files are created 0600/0700 (umask 077).
#   The archive contains plaintext copies of everything in $HOME including secrets.
#   Treat it as sensitive: store it on an encrypted volume or accept the exposure.
#
# WHY THIS ORDER
#   mount check -> free space -> lock -> log rotate -> tmp sweep -> retention ->
#   snapshot-exists gate -> exclusions -> staging -> archive -> integrity gate ->
#   META -> atomic rename. Rerunnable and failure-prone steps all happen before
#   the single irreversible rename at the end.
set -euo pipefail
umask 077

DRY_RUN=0
for a in "$@"; do
    case "$a" in
        --dry-run) DRY_RUN=1 ;;
        -h|--help) sed -n '17,45p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "usage: backup-home.sh [--dry-run]" >&2; exit 2 ;;
    esac
done
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONF="${ENVOI_CONF:-${SCRIPT_DIR}/backup.conf}"
if [[ -f "${CONF}" ]]; then
    # shellcheck source=/dev/null
    source "${CONF}"
fi

HOME_DIR="${ENVOI_HOME_DIR:-$HOME}"
DEST="${ENVOI_DEST:-}"
if [[ -z "${DEST}" ]]; then
    echo "FATAL: ENVOI_DEST is not set — copy backup.conf.example to ${CONF} (or export it)" >&2
    exit 2
fi
SENTINEL="${ENVOI_SENTINEL-}"
HOST_KEY="${ENVOI_LABEL:-$(hostname -s 2>/dev/null || hostname)}"
EXTRA_EXCLUDES="${ENVOI_EXTRA_EXCLUDES-}"

LOG_FILE="${DEST}/backup.log"
if [[ -n "${ENVOI_EXPECT_USER:-}" && "$(id -un)" != "${ENVOI_EXPECT_USER}" ]]; then
    echo "FATAL: this configuration expects user '${ENVOI_EXPECT_USER}' (running as $(id -un))" >&2
    exit 2
fi

fatal() { touch "${HOME}/.backup-fatal" 2>/dev/null || true; { echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: $*"; echo "RESULT: FAILED"; } | tee -a "${LOG_FILE}" >&2 || true; exit 1; }
log()   { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}" >&2 || true; }

# refuse to write backups into the root filesystem if the mount is gone
if [[ -n "${ENVOI_MOUNT:-}" ]] && ! mountpoint -q "${ENVOI_MOUNT}"; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FATAL: ${ENVOI_MOUNT} is not mounted — refusing to write backups onto the root filesystem" >&2
    touch "${HOME}/.backup-fatal" 2>/dev/null || true
    exit 1
fi

# default excludes file lives next to this script; override with ENVOI_EXCLUDES_FILE
EXCLUDES_FILE="${ENVOI_EXCLUDES_FILE:-${SCRIPT_DIR}/backup-excludes.txt}"
LOCK_FILE="${HOME}/.backup.lock"
DATE_STAMP=$(date +%Y-%m-%d)
SNAP="${DEST}/snapshots/${DATE_STAMP}"
SNAP_TMP="${DEST}/snapshots/.tmp-${DATE_STAMP}-$$"
GZIP="pigz -3"; if ! command -v pigz >/dev/null; then GZIP="gzip"; fi

if (( ! DRY_RUN )); then
    mkdir -p "${DEST}/snapshots"
    # fail fast if the target is nearly full — better an early, loud stop than a half-written archive
    FREE_GB=$(df -BG --output=avail "${DEST}" 2>/dev/null | tail -1 | tr -dc '0-9' || true)
    if [[ -z "${FREE_GB}" ]] || (( FREE_GB < ${MIN_FREE_GB:-50} )); then
        fatal "cannot verify free space on ${DEST} (or below ${MIN_FREE_GB:-50}G) — refusing to start"
    fi
fi

# takes (flock) the lock in $HOME; stale locks die with their owner
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "SKIPPED: another backup is already running (lock held)"; exit 0
fi
if (( ! DRY_RUN )) && [[ -f "${LOG_FILE}" && $(stat -c%s "${LOG_FILE}") -gt 1048576 ]]; then
    mv -f "${LOG_FILE}" "${LOG_FILE}.1"
fi
# remove .tmp-* dirs from interrupted runs — only after the lock is held, never under a live one
if (( ! DRY_RUN )); then
    find "${DEST}/snapshots" -mindepth 1 -maxdepth 1 -type d -name '.tmp-*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true
fi
# retention: prune >60d — but only once a verified backup exists, and never the newest one.
# A permanently failing job must not be allowed to starve the disk while eating old history.
if (( ! DRY_RUN )); then
    if [[ -f "${DEST}/.last-backup-success" ]]; then
        NEWEST=$(find "${DEST}/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2-)
        find "${DEST}/snapshots" -mindepth 1 -maxdepth 1 -type d -mtime +60 -print0 | \
            while IFS= read -r -d '' d; do
                if [[ "$d" == "$NEWEST" ]]; then
                    log "Keeping $(basename "$d") — newest snapshot"
                else
                    log "Pruning old snapshot $(basename "$d")"; rm -rf "$d"
                fi
            done || log "WARN: snapshot-retention sweep failed"
        find "${DEST}" -maxdepth 1 -type f -name "*.tar.gz" -mtime +60 -print -delete | \
            while IFS= read -r f; do log "Pruned legacy archive $(basename "$f")"; done || log "WARN: legacy-archive sweep failed"
    else
        log "NOTE: no successful backup on record — retention sweep skipped entirely"
    fi
fi

# one snapshot per day: if today's exists, stop quietly (cron double-fire is harmless)
if [[ -d "${SNAP}" ]]; then
    log "SKIPPED: snapshot ${DATE_STAMP} already exists"; exit 0
fi

# EXIT trap removes the staging dir; HUP/INT/TERM map to signal exit codes
# shellcheck disable=SC2329  # invoked via trap, not directly
cleanup() { rc=$?; rm -rf "${SNAP_TMP}" 2>/dev/null || true; exit "$rc"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Exclusion list is DATA, not code: strict charset, no '..', never sourced —
# a bad line aborts the run instead of executing something. '#' starts a comment.
EXCLUDED_SUBDIRS=()
if [[ -f "${EXCLUDES_FILE}" ]]; then
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line="${raw%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ "$line" == "." || "$line" == "./" || "$line" == *..* || ! "$line" =~ ^[A-Za-z0-9_.][A-Za-z0-9._/-]*$ ]]; then
            fatal "bad line in ${EXCLUDES_FILE}: '${line}'"
        fi
        EXCLUDED_SUBDIRS+=( "$line" )
    done < "${EXCLUDES_FILE}"
else
    fatal "${EXCLUDES_FILE} missing — aborting rather than archiving everything"
fi
if [[ -n "${EXTRA_EXCLUDES}" ]]; then
    read -r -a _extra <<< "${EXTRA_EXCLUDES}"
    EXCLUDED_SUBDIRS+=( "${_extra[@]}" )
fi
EXCLUDED_SUBDIRS+=( ".backup-fatal" ".backup.lock" )

# tar --exclude takes glob patterns; escape our metacharacters so a file named a[1].db
# is treated literally, not as a character class
esc_glob() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\*/\\*}"; s="${s//\?/\\?}"; s="${s//\[/\\[}"; printf '%s' "$s"; }

EXCLUDES=()
for d in "${EXCLUDED_SUBDIRS[@]}"; do EXCLUDES+=( --exclude="$(esc_glob "$d")" ); done

# same exclude set expressed as find(1) -prune for the DB scan below
PRUNE=()
for d in "${EXCLUDED_SUBDIRS[@]}"; do
    p="${d#./}"
    if [[ "$p" == */* ]]; then PRUNE+=( -path "${HOME_DIR}/${p}" -prune -o ); else PRUNE+=( -name "$d" -prune -o ); fi
done

# one shared find for both the real scan and the dry-run count; -xdev stays on $HOME's filesystem
db_find() { find "${HOME_DIR}" -xdev "${PRUNE[@]}" \( -type f \( -name '*.sqlite' -o -name '*.sqlite3' -o -name '*.db' -o -name '*.db3' -o -name '*.s3db' \) \) "$@"; }

if (( DRY_RUN )); then
    echo "DRY RUN host=${HOST_KEY} dest=${DEST}"
    echo "excludes (${#EXCLUDED_SUBDIRS[@]}): ${EXCLUDED_SUBDIRS[*]}"
    TMPD=$(mktemp -d)
    if db_find -print 2>"$TMPD/err" | wc -l > "$TMPD/n"; then
        echo "sqlite/db candidate files: $(cat "$TMPD/n")"
    else
        echo "sqlite/db candidate count: find reported unreadable paths (see stderr); upper bound $(wc -l < "$TMPD/n")"
    fi
    [[ -s "$TMPD/err" ]] && echo "unreadable entries: $(grep -c 'Permission denied' "$TMPD/err")"
    rm -f "$TMPD"/*; rmdir "$TMPD"
    if [[ -n "${SENTINEL}" ]]; then
        [[ -f "${HOME_DIR}/${SENTINEL#./}" ]] && echo "sentinel ${SENTINEL}: present" || echo "sentinel ${SENTINEL}: MISSING"
    else
        echo "sentinel: disabled (ENVOI_SENTINEL unset)"
    fi
    echo "no changes made"
    exit 0
fi

mkdir -p "${SNAP_TMP}/db"
log "Starting ${HOST_KEY} backup -> ${SNAP} (compressor: ${GZIP})"

# stage_db <relpath>: snapshot one SQLite DB into db/<relpath> via the online backup API.
# rc=0 staged; rc=3 not SQLite (archive raw); rc=4 corrupt SQLite (fatal); other rc = failure after retries.
stage_db() {
    local rel="$1" src="${HOME_DIR}/$1" dest="${SNAP_TMP}/db/$1" rc=1
    mkdir -p "$(dirname "${dest}")"
    local attempt=0
    while :; do
        attempt=$((attempt + 1))
        rm -f "${dest}"
        if /usr/bin/python3 - "$src" "$dest" <<'PY'
import sqlite3, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, 'rb') as f:
    magic = f.read(16)
if not magic.startswith(b"SQLite format 3\x00"):
    sys.exit(3)  # not SQLite — archive raw instead
s = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=60)
try:
    s.execute("SELECT 1 FROM sqlite_master LIMIT 1")
except sqlite3.DatabaseError:
    sys.exit(4)  # header says SQLite but it doesn't open — corrupt; do not archive raw
d = sqlite3.connect(dst)
try:
    s.backup(d)  # consistent snapshot; never a torn copy of a hot database
finally:
    d.close(); s.close()
PY
        then
            rc=0; break
        else
            rc=$?
            [[ $rc -eq 3 ]] && break          # not SQLite, no point retrying
            [[ $rc -eq 4 ]] && break          # corrupt SQLite — fatal, no retry
            if (( attempt < 3 )); then sleep 5; continue; fi
            break
        fi
    done
    if [[ $rc -eq 0 ]]; then
        local esc; esc=$(esc_glob "$rel")
        EXCLUDES+=( --exclude="${esc}" --exclude="${esc}-wal" --exclude="${esc}-shm" --exclude="${esc}-journal" )
        STAGED_RELS+=( "$rel" )
    elif [[ $rc -eq 3 ]]; then
        rm -f "${dest}"; log "note: not SQLite, archiving raw: ${rel}"
    elif [[ $rc -eq 4 ]]; then
        rm -f "${dest}"; fatal "corrupt SQLite database: ${rel}"
    else
        fatal "SQLite snapshot failed for ${rel}"
    fi
}

# find the DB candidates; rc 1 = unreadable paths (tolerated), rc >1 = real error
STAGED_RELS=()
DB_LIST="${SNAP_TMP}/db_list"
FIND_RC=0
if db_find -print0 > "${DB_LIST}" 2> "${SNAP_TMP}/db_find.err"; then
    FIND_RC=0
else
    FIND_RC=$?
fi
# NOTE: a bare "db_find ... >file" would kill the script under set -e before we can read $?
# — hence the if/else form.
if (( FIND_RC > 1 )); then
    fatal "find failed (exit ${FIND_RC}) scanning ${HOME_DIR}"
fi
if [[ -s "${SNAP_TMP}/db_find.err" ]]; then
    log "NOTE: find skipped unreadable paths ($(grep -c 'Permission denied' "${SNAP_TMP}/db_find.err" || true) permission errors; kept in db_find.err)"
fi
while IFS= read -r -d '' f; do
    case "$f" in
        "${HOME_DIR}"/*) rel="${f#"${HOME_DIR}"/}" ;;
        *) log "WARN: skipping unexpected path outside ${HOME_DIR}: $f"; continue ;;
    esac
    stage_db "$rel"
done < "${DB_LIST}"
rm -f "${DB_LIST}"
log "Staged ${#STAGED_RELS[@]} live DB snapshot(s)"

# create the archive; member list goes to stdout (captured), warnings go to the log —
# tar must receive -f <file>, or stdout IS the archive and members.txt would hold it
TAR_RC=0
if tar --one-file-system -I "${GZIP}" -cvf "${SNAP_TMP}/home.tar.gz" "${EXCLUDES[@]}" -C "${HOME_DIR}" . >"${SNAP_TMP}/members.txt" 2>>"${LOG_FILE}"; then
    TAR_RC=0
else
    TAR_RC=$?
fi
if [[ ${TAR_RC} -gt 1 ]]; then
    fatal "tar failed with exit ${TAR_RC}"
fi
[[ ${TAR_RC} -eq 1 ]] && log "NOTE: tar flagged files changed during read (live writers) — archive still valid"

MEMBER_COUNT=$(wc -l < "${SNAP_TMP}/members.txt")
# every staged DB must exist and be non-empty (stat only, no reads)
DB_OK=1
if (( ${#STAGED_RELS[@]} )); then
    while IFS= read -r rel; do
        if [[ ! -s "${SNAP_TMP}/db/${rel}" ]]; then
            DB_OK=0; log "ERROR: staged DB missing or empty: ${rel}"
        fi
    done < <(printf '%s\n' "${STAGED_RELS[@]}")
fi
# archive passes only if staged DBs exist, member count clears the floor, and the sentinel is an exact member line
SENTINEL_OK=1
if [[ -n "${SENTINEL}" ]]; then
    grep -qxF "${SENTINEL}" "${SNAP_TMP}/members.txt" || SENTINEL_OK=0
fi
if [[ ${DB_OK} -eq 1 ]] && [[ ${MEMBER_COUNT} -gt ${MIN_MEMBERS:-100} ]] && [[ ${SENTINEL_OK} -eq 1 ]]; then
    SIZE=$(du -h "${SNAP_TMP}/home.tar.gz" | cut -f1)
    printf 'host=%s\ndate=%s\nhome_tar_members=%s\nhome_tar_size=%s\ndb_snapshots=%s\n' \
        "$HOST_KEY" "$DATE_STAMP" "$MEMBER_COUNT" "$SIZE" "${#STAGED_RELS[@]}" > "${SNAP_TMP}/META"
    PROV_SRC="$(readlink -f "${BASH_SOURCE[0]}")"
    if ! cp "${PROV_SRC}" "${SNAP_TMP}/backup-home.sh" || ! cp "${EXCLUDES_FILE}" "${SNAP_TMP}/backup-excludes.txt"; then
        fatal "failed to copy provenance files into snapshot"
    fi
    # literal $HOME etc. are for the human restoring, not for this shell
    # shellcheck disable=SC2016
    printf '%s\n' \
        'Restore:' \
        '  1. stop the service(s) using these files' \
        '  2. as the target user: tar -xzf home.tar.gz -C $HOME' \
        '  3. rm -f the -wal/-shm/-journal sidecars for every db/ file you will restore, next to its target path' \
        '  4. cp -a db/. $HOME/' \
        '  5. chown -R $(id -un):$(id -gn) $HOME; chmod 700 $HOME/.ssh && chmod 600 $HOME/.ssh/*'  \
        '  6. verify: sqlite3 <db> "PRAGMA quick_check;" must print ok' \
        '  7. reinstall the app/watched services/cron jobs that are NOT in this archive (toolchains, agents, cron entries)' \
        > "${SNAP_TMP}/RESTORE.txt"
    mv -T "${SNAP_TMP}" "${SNAP}" || fatal "snapshot rename to ${SNAP} failed"
    log "Backup complete: ${SNAP} (${SIZE}, ${MEMBER_COUNT} members, ${#STAGED_RELS[@]} DBs)"
    touch "${DEST}/.last-backup-success" || log "WARN: could not write ${DEST}/.last-backup-success"
    rm -f "${HOME}/.backup-fatal" || true
else
    SENTINEL_MSG=disabled
    if [[ -n "${SENTINEL}" ]]; then
        grep -qxF "${SENTINEL}" "${SNAP_TMP}/members.txt" && SENTINEL_MSG=found || SENTINEL_MSG=MISSING
    fi
    fatal "archive failed integrity check (members=${MEMBER_COUNT}, sentinel '${SENTINEL}' ${SENTINEL_MSG})"
fi

log "RESULT: OK"
exit 0
