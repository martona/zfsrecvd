#!/usr/bin/env bash
# Unit tests for report.sh against a synthetic runs.jsonl. Pure bash+awk,
# runs anywhere: ./test-report.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX=$(mktemp -d)
trap 'rm -rf "$FX"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS: $*"; PASS=$((PASS+1)); }
bad() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }

cat > "$FX/runs.jsonl" <<'EOF'
{"ts":"2026-07-29T01:00:00Z","snap":"zfsrecvd-2026-07-29-0100Z","src":"jup","tree":"tank/a","dst":"berg","state":"done","rc":"0","why":"","failed_ds":"","secs":10}
{"ts":"2026-07-29T01:00:00Z","snap":"zfsrecvd-2026-07-29-0100Z","src":"jup","tree":"tank/a","dst":"cp4","state":"done","rc":"0","why":"","failed_ds":"","secs":12}
{"ts":"2026-07-29T01:01:00Z","kind":"run","run":"run-A","rc":0,"recv":[{"id":"berg","before":1000,"after":2024,"avail":5000000,"pruned":100},{"id":"cp4","before":500,"after":800,"avail":900000,"pruned":0}],"src":[{"id":"jup","tree":"tank/a","used":123456,"avail":777777}]}
{"ts":"2026-07-30T01:00:00Z","snap":"zfsrecvd-2026-07-30-0100Z","src":"jup","tree":"tank/a","dst":"berg","state":"done","rc":"0","why":"","failed_ds":"","secs":9}
{"ts":"2026-07-30T01:00:00Z","snap":"zfsrecvd-2026-07-30-0100Z","src":"jup","tree":"tank/a","dst":"cp4","state":"done","rc":"2","why":"some datasets failed","failed_ds":"tank/a/vol tank/a/deep","secs":44}
{"ts":"2026-07-30T01:01:00Z","kind":"run","run":"run-B","rc":2,"recv":[{"id":"berg","before":2024,"after":4072,"avail":4990000,"pruned":512},{"id":"cp4","before":800,"after":800,"avail":900000,"pruned":0}],"src":[{"id":"jup","tree":"tank/a","used":200000,"avail":700000}]}
EOF

out=$(bash "$HERE/report.sh" -f "$FX/runs.jsonl" 2>&1)
rc=$?
[[ $rc -eq 0 ]] && ok "renders rc=0" || { bad "rc=$rc"; echo "$out"; }
grep -q "last run: run-B" <<<"$out" && ok "latest run selected" || bad "latest: $out"
grep -q "jobs: 1 ok, 1 not ok" <<<"$out" && ok "job tally" || bad "tally: $out"
grep -q "FAIL  \[jup\] tank/a -> \[cp4\]" <<<"$out" && ok "failure drilldown line" || bad "fail line: $out"
grep -q "datasets: tank/a/vol tank/a/deep" <<<"$out" && ok "failed_ds surfaced" || bad "failed_ds: $out"
grep -q "recv berg.*net 2.0K" <<<"$out" && ok "receiver net humanized" || bad "net: $out"
grep -q "src  jup.*tank/a: used 195.3K" <<<"$out" && ok "source space line" || bad "src: $out"
grep -q "trend (last 2 run(s))" <<<"$out" && ok "trend window" || bad "trend hdr: $out"
grep -q "berg.*net 3.0K, pruned 612B" <<<"$out" && ok "trend sums" || bad "trend: $out"
grep -q "runs with nonzero rc: 1" <<<"$out" && ok "trend failure count" || bad "trend fails: $out"

out1=$(bash "$HERE/report.sh" -n 1 -f "$FX/runs.jsonl" 2>&1)
grep -q "trend (last 1 run(s))" <<<"$out1" && ok "-n limits window" || bad "-n: $out1"
grep -q "berg.*net 2.0K, pruned 512B" <<<"$out1" && ok "-n=1 sums only last" || bad "-n sums: $out1"

echo "=== RESULT: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
