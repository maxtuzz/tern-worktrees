#!/usr/bin/env bash
# Runs the Luau tests (bundled, see tests/bundle.py) and the setup-script test.
set -euo pipefail
cd "$(dirname "$0")/.."
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
python3 tests/bundle.py > "$out/bundle.luau"
luau "$out/bundle.luau"
bash tests/setup_e2e.sh
