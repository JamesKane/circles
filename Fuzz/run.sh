#!/usr/bin/env bash
# Usage: run.sh <target|all> [seconds]
set -euo pipefail
cd "$(dirname "$0")"
seconds=${2:-60}
swift build -c release -Xswiftc -sanitize=fuzzer,address 2>&1 | grep -E "error" || true
binary=.build/release/circles-fuzz
targets=$1
if [ "$targets" = all ]; then targets="cbor types verify noise texts dht push sync mls"; fi
mkdir -p crashes
for target in $targets; do
    mkdir -p "corpus/$target"
    echo "== $target ($seconds s)"
    ASAN_OPTIONS=detect_leaks=0 CIRCLES_FUZZ_SEED_DIR="corpus/$target" CIRCLES_FUZZ_TARGET="$target" "$binary" "corpus/$target" -max_total_time="$seconds" -timeout=10 -detect_leaks=0 -rss_limit_mb=4096 \
        -artifact_prefix="crashes/$target-" -print_final_stats=1 2>&1 | grep -E "^#|DONE|ERROR|SUMMARY|stat::number_of_executed_units|crash" | tail -4
done
