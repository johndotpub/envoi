#!/usr/bin/env bats
# Tests for backup-home.sh — all runs happen against a scratch fixture dir,
# never against a real home directory or backup destination.

setup() {
  FIX="$BATS_TEST_TMPDIR/fix"
  mkdir -p "$FIX/home/.hermes" "$FIX/home/sub" "$FIX/dest" "$FIX/fakehome"
  printf 'cfg' > "$FIX/home/.hermes/config.yaml"
  python3 -c "import sqlite3; c=sqlite3.connect('$FIX/home/.hermes/state.db'); c.execute('create table t(a)'); c.execute('insert into t values (7)'); c.commit()"
  printf z > "$FIX/home/sub/random.db"
  printf keepme > "$FIX/home/sub/keep.txt"
  cp "$BATS_TEST_DIRNAME/../backup-home.sh" "$FIX/backup-home.sh"
  # synthetic excludes — the real backup-excludes.txt is machine-specific and gitignored
  printf './go\n.venv\n' > "$FIX/backup-excludes.txt"
  chmod +x "$FIX/backup-home.sh"
  export ENVOI_HOME_DIR="$FIX/home" ENVOI_DEST="$FIX/dest" ENVOI_SENTINEL=./.hermes/config.yaml
  export MIN_FREE_GB=1 MIN_MEMBERS=3 HOME="$FIX/fakehome"
  run_env() { bash "$FIX/backup-home.sh" "$@"; }
}

teardown() { rm -rf "$BATS_TEST_TMPDIR"; }

@test "happy path: archive, META, member list, DBs excluded from tar, sentinel present" {
  run run_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: OK"* ]]
  SNAP=$(ls -d "$FIX"/dest/snapshots/*/)
  [ -f "$SNAP/home.tar.gz" ]
  [ -f "$SNAP/META" ]
  [ -f "$SNAP/members.txt" ]
  tar -tzf "$SNAP/home.tar.gz" | grep -qx './.hermes/config.yaml'
  ! tar -tzf "$SNAP/home.tar.gz" | grep -q 'state.db'
  [ -f "$SNAP/db/.hermes/state.db" ]
}

@test "restore drill: extracted DB reads back the row" {
  run_env >/dev/null
  SNAP=$(ls -d "$FIX"/dest/snapshots/*/)
  mkdir -p "$FIX/restore"
  tar -xzf "$SNAP/home.tar.gz" -C "$FIX/restore"
  cp "$SNAP/db/.hermes/state.db" "$FIX/restore/.hermes/state.db"
  ROW=$(python3 -c "import sqlite3;print(sqlite3.connect('$FIX/restore/.hermes/state.db').execute('select a from t').fetchone()[0])")
  [ "$ROW" = "7" ]
}

@test "corrupt DB aborts the run non-zero and names the file" {
  printf 'SQLite format 3\000garbage garbage' > "$FIX/home/.hermes/state.db"
  run run_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"corrupt SQLite"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"corrupt SQLite"* ]]
}

@test "zero-byte .db is archived raw, not fatal" {
  : > "$FIX/home/sub/random.db"
  run run_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"archiving raw"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"archiving raw"* ]]
}

@test "sentinel missing from archive fails the run" {
  rm "$FIX/home/.hermes/config.yaml"
  run run_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"integrity check"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"integrity check"* ]]
}

@test "missing excludes file aborts rather than archiving everything" {
  rm "$FIX/backup-excludes.txt"
  run run_env
  [ "$status" -eq 1 ]
  [[ "$output" == *"missing"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"missing"* ]] || [ -f "$FIX/fakehome/.backup-fatal" ]
}

@test "wrong user is refused when ENVOI_EXPECT_USER is set" {
  export ENVOI_EXPECT_USER=definitely-not-me
  run run_env
  [ "$status" -eq 2 ]
}

@test "lock held: second invocation skips with rc 0" {
  ( exec 9>"$FIX/fakehome/.backup.lock"; flock -n 9; sleep 2 ) &
  LOCKPID=$!
  sleep 0.2
  run run_env
  kill $LOCKPID 2>/dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"SKIPPED"* ]]
}

@test "already-done today skips silently with rc 0" {
  run_env >/dev/null
  run run_env
  [ "$status" -eq 0 ]
  [[ "$output" == *"already exists"* ]] || [[ "$(cat "$FIX/dest/backup.log")" == *"already exists"* ]]
}

@test "retention: nothing pruned when no success marker exists" {
  mkdir -p "$FIX/dest/snapshots/2001-01-01" "$FIX/dest/snapshots/2002-01-01"
  touch -d '2001-01-01' "$FIX/dest/snapshots/2001-01-01" "$FIX/dest/snapshots/2002-01-01"
  run run_env >/dev/null
  [ -d "$FIX/dest/snapshots/2001-01-01" ]
  [ -d "$FIX/dest/snapshots/2002-01-01" ]
}

@test "retention: marker present — oldest pruned, newest kept" {
  mkdir -p "$FIX/dest/snapshots/2001-01-01" "$FIX/dest/snapshots/2002-01-01"
  touch -d '2001-01-01' "$FIX/dest/snapshots/2001-01-01" "$FIX/dest/snapshots/2002-01-01"
  touch "$FIX/dest/.last-backup-success"
  run run_env >/dev/null
  [ ! -d "$FIX/dest/snapshots/2001-01-01" ]
  [ -d "$FIX/dest/snapshots/2002-01-01" ]
}

@test "dry run reports and writes nothing" {
  BEFORE=$(ls -A "$FIX/dest" | wc -l)
  run run_env --dry-run
  AFTER=$(ls -A "$FIX/dest" | wc -l)
  [ "$BEFORE" = "$AFTER" ]
  [[ "$output" == *"no changes made"* ]]
}

@test "anchored ./go excludes root-level go, keeps nested go/" {
  mkdir -p "$FIX/home/go/src" "$FIX/home/sub/go"
  printf x > "$FIX/home/go/src/main.go"
  printf y > "$FIX/home/sub/go/keep.go"
  run run_env
  [ "$status" -eq 0 ]
  tar -tzf "$FIX"/dest/snapshots/*/home.tar.gz > "$FIX/members"
  ! grep -q '^\./go/' "$FIX/members"
  grep -q '^\./sub/go/keep.go$' "$FIX/members"
}
