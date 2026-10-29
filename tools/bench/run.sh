#!/bin/bash
# tools/bench/run.sh TAG [views...]: render every benchmark view (plus its
# water mask) into bench/out/TAG/, and collect the timings in report.json.
#   GODOT=/path/to/godot tools/bench/run.sh before
set -e
GODOT="${GODOT:-godot}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TAG="$1"; shift || true
VIEWS=${@:-"headwater rapids lowland island mouth falls_front falls_pool falls_lip falls_above falls_low upstream ocean"}
OUT="$ROOT/bench/out/$TAG"
mkdir -p "$OUT"
: > "$OUT/report.jsonl"
cd "$ROOT"
for v in $VIEWS; do
	for mask in "" $([ "${MASKS:-1}" = 0 ] || echo 1); do
		suffix=${mask:+_mask}
		VIEW=$v MASK=$mask OUT="$OUT/$v$suffix.png" FRAMES=${FRAMES:-120} \
			xvfb-run -a -s "-screen 0 960x540x24" "$GODOT" --path . --resolution 960x540 --fixed-fps 60 -s tools/bench/run.gd 2>/dev/null \
			| grep "^BENCH " | sed 's/^BENCH //' >> "$OUT/report.jsonl" || true
	done
done
python3 tools/bench/metrics.py "$OUT" > "$OUT/metrics.txt" || true
cat "$OUT/metrics.txt"
