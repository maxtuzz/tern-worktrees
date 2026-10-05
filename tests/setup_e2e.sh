#!/usr/bin/env bash
# Compiles a post_create script and runs it with /bin/bash (3.2 on macOS)
# against a fake main worktree, then checks what it did.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
main="$tmp/main"; wt="$tmp/wt"
mkdir -p "$main/apps/web" "$main/shared" "$main/.hamster" "$wt"
echo ROOT=1 > "$main/.env"
echo WEB=1 > "$main/apps/web/.env"
echo keep > "$wt/.env"
echo plan > "$main/.hamster/plan.md"
python3 tests/bundle.py emit_setup > "$tmp/emit.luau"
# Fill in the fixture paths (the bundle takes no program arguments).
sed -i.bak -e "s|@WT_PATH@|$wt|" -e "s|@WT_MAIN@|$main|" "$tmp/emit.luau"
luau "$tmp/emit.luau" > "$tmp/setup.sh"
/bin/bash "$tmp/setup.sh" > "$tmp/out.txt" 2>&1 || { cat "$tmp/out.txt"; echo "setup script failed"; exit 1; }
fail() { cat "$tmp/out.txt"; echo "FAIL: $1"; exit 1; }
[ "$(cat "$wt/.env")" = keep ] || fail "if_missing overwrote .env"
[ "$(cat "$wt/apps/web/.env")" = WEB=1 ] || fail "glob copy"
[ -L "$wt/shared" ] || fail "symlink"
[ "$(cat "$wt/.hamster/plan.md")" = plan ] || fail "sync_dir"
[ "$(cat "$wt/ran.txt")" = "feat/x:true" ] || fail "run with env"
grep -q "optional step failed" "$tmp/out.txt" || fail "optional missing dir should warn"
grep -q "post_create done" "$tmp/out.txt" || fail "done marker"
echo "setup e2e passed"
