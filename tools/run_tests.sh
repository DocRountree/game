#!/bin/sh
# Run the headless test suite. Exit code is non-zero if any test fails.
set -e
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$GODOT" --headless --path "$ROOT" --import >/dev/null 2>&1 || true
status=0
for test in "$ROOT"/tests/*_test.gd; do
	name="$(basename "$test")"
	echo "== $name"
	"$GODOT" --headless --path "$ROOT" -s "res://tests/$name" || status=1
done
exit $status
