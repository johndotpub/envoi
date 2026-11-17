# Changelog

## 1.0.0 — 2026-11-16

First public release.

**What it is.** A single-bash-script backup for live Linux home directories:
one streaming tar+pigz archive of the tree, live SQLite databases snapshotted
through the online backup API, and a hard integrity gate before anything is
declared done.

**Backup engine**

- Single-pass streaming archive (`tar | pigz`), `--one-file-system`, no intermediate tar file
- SQLite DBs detected by magic header, snapshotted with the online backup API,
  excluded from the tar stream, restored by copying `db/` back over the tree
- Non-SQLite `.db`/`.sqlite*` files archived raw, byte-for-byte
- Live-database corruption (valid header, unreadable pages) aborts the run
  loudly instead of archiving garbage

**Integrity gate** (checked every run, before the snapshot is renamed into place)

- Member count must exceed a floor (default 100)
- Configured sentinel file must be present as an exact member line
- Every staged DB snapshot must exist and be non-empty
- Any failure: `~/.backup-fatal` written, non-zero exit, `backup.log` says why

**Layout & safety**

- Snapshots land in `snapshots/YYYY-MM-DD/` via atomic rename from a hidden
  `.tmp-*` staging dir; interrupted runs never look like finished ones
- 60-day retention — but nothing is pruned until a verified backup exists,
  the newest snapshot is never pruned, and retention runs before the new
  backup so a full disk stops the job, not the cleanup
- Lock in `$HOME` (survives nothing, dies with the process); `flock`, not stale files
- `umask 077`; snapshots and log are 0700/0600

**Operation**

- Per-host configuration in `backup.conf` (gitignored) or the environment;
  `backup.conf.example` documents every knob
- `--dry-run` reports what would happen and touches nothing
- Exit codes: 0 = ok (or deliberate skip), 1 = failed, 2 = misuse,
  129/130/143 = signalled
- Daily-snap guard: an already-complete snapshot for today short-circuits cron retries
- Retention is mtime-based; logs rotate at ~1 MB
- Dry-run, locking, and cron-friendliness documented; no external services

**Platform notes**

- Developed and tested on Ubuntu 24.04 and on 9p/drvfs (Windows-mounted) disks;
  no reliance on unix ownership or permissions there
- `pigz` optional (falls back to `gzip`)

**Testing**

- 13-case BATS suite: happy path, restore drill (extracted DB reads back
  correctly), corrupt-DB handling, zero-byte DB passthrough, retention both
  directions, lock contention, already-done-today skip, dry-run, anchored
  excludes, wrong-user refusal

**Known limitations**

- File-level only; no block-level/incremental dedup
- Archives are unencrypted (see README — encrypt the destination)
- Cross-filesystem trees require `--one-file-system` semantics to be correct
  for your layout; review before first real run
