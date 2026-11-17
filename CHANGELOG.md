# Changelog

## 0.1.0 — 2026-11-16

Initial public release.

- Single-pass streaming tar + pigz backup of a live Linux home directory
- Live SQLite databases snapshotted via the SQLite online backup API and
  excluded from the tar stream; everything else archived in one pass
- Integrity gate on every run: member count floor, sentinel file check,
  staged-DB presence; any failure touches `~/.backup-fatal` and exits non-zero
- 60-day retention, pruned only after a verified backup exists, newest kept
- Retention and pruning run before the new backup; snapshot is built in a
  hidden staging dir and renamed into place atomically
- Config via `backup.conf` or environment — no code edits per host
- Handles 9p/drvfs Windows mounts (no permissions, no unix ownership) without
  relying on either
- zsh-friendly bash, no dependencies beyond coreutils, GNU tar, findutils,
  pigz (falls back to gzip), python3 with sqlite3
- BATS test suite covering the happy path, restore drill, and every failure
  mode the author could think of
