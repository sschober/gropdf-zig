#!/usr/bin/env bash
# bench.sh — reproduce the README performance comparison
# Usage: ./bench.sh [runs]
set -euo pipefail

RUNS=${1:-50}
MOM=samples/input.mom
GROUT=samples/input.grout

# ── build ────────────────────────────────────────────────────────────────────
echo "Building debug…"
zig build
echo "Building release…"
zig build -Doptimize=ReleaseFast --prefix zig-out-rel

DBG_BIN=./zig-out/bin/gropdf_zig
REL_BIN=./zig-out-rel/bin/gropdf_zig

# ── ensure grout file ────────────────────────────────────────────────────────
if [[ ! -f "$GROUT" ]]; then
    echo "Generating $GROUT…"
    groff -Tpdf -Z -mom "$MOM" > "$GROUT"
fi
echo

# ── timing helper ─────────────────────────────────────────────────────────────
# run_bench <cmd...>  — runs cmd RUNS times and echoes mean milliseconds (int).
run_bench() {
    local total_ns=0 i t0 t1
    for i in $(seq 1 "$RUNS"); do
        t0=$(date +%s%N)
        "$@" > /dev/null 2>&1
        t1=$(date +%s%N)
        total_ns=$(( total_ns + t1 - t0 ))
    done
    LC_ALL=C awk -v t="$total_ns" -v n="$RUNS" 'BEGIN{ printf "%.0f", t/n/1e6 }'
}

# ── benchmarks ───────────────────────────────────────────────────────────────
echo "Benchmarking ($RUNS runs each)…"
echo

printf "%-24s" "gropdf (perl)…"
pl_ms=$( run_bench groff -Tpdf -mom "$MOM" )
printf "%5s ms\n" "$pl_ms"

printf "%-24s" "gropdf.zig (debug)…"
dbg_ms=$( run_bench bash -c "$DBG_BIN < $GROUT" )
printf "%5s ms\n" "$dbg_ms"

printf "%-24s" "gropdf.zig (release)…"
rel_ms=$( run_bench bash -c "$REL_BIN < $GROUT" )
printf "%5s ms\n" "$rel_ms"

echo
echo "measures.lst:"
printf "gropdf.pl %s\ngropdf_zig %s\ngropdf_zig_rel %s\n" \
    "$pl_ms" "$dbg_ms" "$rel_ms"
