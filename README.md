# envoi

Back up a live Linux home directory to a local or mounted disk — every week,
unattended, without copying half-written SQLite files into your backup.

An **envoi** is the closing stanza of a poem: the part that goes back out into
the world carrying everything that mattered. That's the job of this script.

## Why not rsync?

`rsync -a ~/ dest/` is 90% of this and it's fine for what it does. It is not
fine for:

- **Live SQLite databases.** Apps using WAL write partial pages while rsync
  reads them. You get a backup that *looks* consistent and restores to a
  database that throws `database disk image is malformed`. envoi snapshots
  every SQLite DB with the online backup API (`sqlite3` C API), so readers
  never block and you never get a torn page.
- **Knowing the backup worked.** envoi verifies every run before it declares
  success: archive opens, member count is sane, a sentinel file you choose is
  present in the member list, and every staged DB snapshot exists and is
  non-empty. Any failure aborts the run and marks `$HOME/.backup-fatal`.
- **Not eating your disk.** Retention prunes beyond 60 days — but never while
  a backup is unverified, never the newest snapshot, and never while today's
  own run is in flight.
- **Nine-P and drvfs mounts** (Windows-mounted drives) where Unix ownership
  and permissions don't exist. envoi avoids depending on them.

## Requirements

bash, GNU tar, coreutils, findutils, python3 (for SQLite handling), and
`pigz` (optional — falls back to `gzip`). Developed on Ubuntu 24.04, including
on `/mnt/<drive>` 9p/drvfs mounts.

## Quickstart

```bash
git clone <this-repo> envoi && cd envoi
cp backup.conf.example backup.conf   # edit it — see below
./backup-home.sh --dry-run           # show what would happen, change nothing
./backup-home.sh                     # run it
```

Wire it into cron (weekly is what it was built for):

```
0 4 * * 0  /home/you/envoi/backup-home.sh
```

Then once a month, actually restore a snapshot into a scratch directory and
check your data. envoi makes the restore boring, not unnecessary.

## Configuration

Everything lives in `backup.conf` (gitignored) next to the script, or in the
environment. Environment wins over the file.

| Variable | Default | Meaning |
|---|---|---|
| `ENVOI_DEST` | *(required)* | Directory snapshots are written to |
| `ENVOI_HOME_DIR` | `$HOME` | Tree to back up |
| `ENVOI_SENTINEL` | unset | Path that must exist in every archive (e.g. `.profile`) |
| `ENVOI_MOUNT` | unset | Mount point that must be present, e.g. `/mnt/backups` |
| `ENVOI_EXPECT_USER` | unset | Refuse to run as any other user |
| `ENVOI_LABEL` | hostname | Label used in logs and snapshot metadata |
| `ENVOI_EXTRA_EXCLUDES` | unset | Space-separated extra exclusions for this host |
| `ENVOI_EXCLUDES_FILE` | `backup-excludes.txt` next to the script | Exclusions file |
| `MIN_MEMBERS` | `100` | Archive must contain more than this many members |
| `MIN_FREE_GB` | `50` | Abort if the destination drops below this much free space |

`backup.conf.example` is a fully commented starting point.

## Excludes

`backup-excludes.txt` is deliberately **not** committed — it encodes what
your machine cares about (caches, `.venv`s, model weights, `.git` internals,
whatever else reproduces itself). Copy `backup-excludes.example.txt` and make
it yours. Format, matching the script's own parser:

- one path per line, relative to `$HOME`
- `#` starts a comment; blank lines are ignored
- an entry containing `/` is matched **anchored at `$HOME`** (e.g. `./go` —
  your own `go/` in `$HOME` — but not `~/project/vendor/go/`)
- a bare name (no slash) matches that basename **at any depth** (e.g. `.venv`)

The leading-anchor rule exists so that excluding `./go` doesn't delete every
`go/` directory anywhere in your tree, and excluding `node_modules` doesn't
depend on where it sits.

## What a run looks like

```
/home/you/backups/snapshots/2026-11-16/
  home.tar.gz      # the tree, minus live DBs and excluded paths
  db/              # consistent, online-backed-up copies of live SQLite DBs
  members.txt      # tar's member list, captured during creation (integrity gate)
  META             # host, date, counts, sizes
  backup-home.sh   # the exact script that made this snapshot
  backup-excludes.txt
  (backup.conf never leaves your machine — it is gitignored and not copied)
  RESTORE.txt      # restore instructions, baked into the snapshot
  db_find.err      # paths find could not read, if any
```

On success: `$HOME/.backup-fatal` is removed, `.last-backup-success` is
touched. On failure: `.backup-fatal` is written and the script exits non-zero,
so a cron-watching wrapper can page you.

Order of operations is deliberate: preflight (destination, space, lock, prune,
stale-temp sweep) all happens before the irreversible `mv` into place. A kill
mid-run leaves a `.tmp-*` directory, never a half-made snapshot masquerading
as complete.

## Restoring

`RESTORE.txt` inside each snapshot is the authoritative version. Short form:

1. Stop whatever writes those files.
2. Remove stale `-wal` / `-shm` / `-journal` sidecars next to each restored DB.
3. `tar -xzf home.tar.gz -C <target-home>`
4. `cp -a db/. <target-home>/`
5. `chown`, then `sqlite3 <db> 'PRAGMA quick_check;'` before starting services.

Test this on a sacrificial directory before you trust it. That's the whole
deal with backups.

## Security notes

- **The archive contains everything in `$HOME`, including secrets.** Anyone
  who can read the destination can read your keys. Store it on encrypted
  storage or accept the exposure consciously.
- Exclusions are a data file with a strict charset whitelist — never sourced,
  never evaluated, so a hostile excludes file can't execute code.
- The script refuses to run as the wrong user if `ENVOI_EXPECT_USER` is set.
- Snapshot directories are world-visible if the destination is; use a
  private destination (`umask 077` is already in effect).

## Development

```bash
bats tests/backup-home.bats
```

Tests build a fully synthetic fixture (fake home, fake SQLite DB) and never
touch a real backup destination. They cover: happy path, restore drill,
corrupt-DB detection, zero-byte DB handling, retention gating (both
directions), lock contention, the dry-run, and the excludes anchor rule.

## License

[Unlicense](LICENSE) — public domain. Do whatever you want with it,
including nothing.
