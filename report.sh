#!/usr/bin/env bash
# report.sh [-n runs] [-f runs.jsonl] -- render the latest run and a
# trend window from the jsonl feed (orchestrate writes per-job lines,
# fleetrun appends one kind:run line AFTER its jobs; grouping is
# positional on that ordering). Parses only our own stable output --
# plain awk (mawk-safe), no jq dependency.
set -euo pipefail

n=10
f=""
while (( $# > 0 )); do
    case "$1" in
        -n) n="${2:?}"; shift 2 ;;
        -f) f="${2:?}"; shift 2 ;;
        *)  echo "usage: report.sh [-n runs] [-f runs.jsonl]" >&2; exit 64 ;;
    esac
done
if [[ -z "$f" ]]; then
    for c in /var/log/zfsrecvd/runs.jsonl "${XDG_STATE_HOME:-$HOME/.local/state}/zfsrecvd/runs.jsonl"; do
        if [[ -s "$c" ]]; then f="$c"; break; fi
    done
fi
if [[ -z "$f" || ! -s "$f" ]]; then
    echo "no runs.jsonl found (looked in /var/log/zfsrecvd and the state dir)" >&2
    exit 1
fi

awk -v NRUNS="$n" '
function g(s, k,   m) {
    m = ""
    if (match(s, "\"" k "\":\"[^\"]*\"")) {
        m = substr(s, RSTART, RLENGTH)
        sub("\"" k "\":\"", "", m); sub("\"$", "", m)
    } else if (match(s, "\"" k "\":-?[0-9]+")) {
        m = substr(s, RSTART, RLENGTH)
        sub("\"" k "\":", "", m)
    }
    return m
}
function h(b,   s, a) {
    s = (b < 0 ? "-" : ""); a = (b < 0 ? -b : b)
    if (a >= 1099511627776) return s sprintf("%.1fT", a / 1099511627776)
    if (a >= 1073741824)    return s sprintf("%.1fG", a / 1073741824)
    if (a >= 1048576)       return s sprintf("%.1fM", a / 1048576)
    if (a >= 1024)          return s sprintf("%.1fK", a / 1024)
    return s a "B"
}
/"kind":"run"/ {
    runs++
    rline[runs] = $0
    jstart[runs] = jdone + 1; jend[runs] = jn; jdone = jn
    next
}
{ jn++; J[jn] = $0 }
END {
    if (runs == 0) { print "no complete runs recorded yet"; exit }
    r = runs
    printf "last run: %s  (%s, rc %s)\n", g(rline[r], "run"), g(rline[r], "ts"), g(rline[r], "rc")
    ok = 0; bad = 0
    for (i = jstart[r]; i <= jend[r]; i++) {
        st = g(J[i], "state"); rc = g(J[i], "rc")
        if (st == "done" && rc == "0") { ok++; continue }
        bad++
        fd = g(J[i], "failed_ds")
        printf "  FAIL  [%s] %s -> [%s]  (%s rc=%s) %s%s\n", \
            g(J[i], "src"), g(J[i], "tree"), g(J[i], "dst"), st, rc, \
            g(J[i], "why"), (fd != "" ? "; datasets: " fd : "")
    }
    printf "  jobs: %d ok, %d not ok\n", ok, bad
    line = rline[r]
    while (match(line, "\\{\"id\":\"[^\"]*\",\"before\":[^}]*\\}")) {
        rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        printf "  recv %-16s net %-8s pruned %-8s avail %s\n", g(rec, "id"), \
            h(g(rec, "after") - g(rec, "before")), h(g(rec, "pruned") + 0), h(g(rec, "avail") + 0)
    }
    line = rline[r]
    while (match(line, "\\{\"id\":\"[^\"]*\",\"tree\":[^}]*\\}")) {
        rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        printf "  src  %-16s %s: used %s, avail %s\n", g(rec, "id"), \
            g(rec, "tree"), h(g(rec, "used") + 0), h(g(rec, "avail") + 0)
    }
    lo = (runs - NRUNS + 1 < 1 ? 1 : runs - NRUNS + 1)
    printf "trend (last %d run(s)):\n", runs - lo + 1
    for (x = lo; x <= runs; x++) {
        line = rline[x]
        while (match(line, "\\{\"id\":\"[^\"]*\",\"before\":[^}]*\\}")) {
            rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
            id = g(rec, "id")
            tnet[id] += g(rec, "after") - g(rec, "before")
            tpr[id]  += g(rec, "pruned") + 0
        }
        if (g(rline[x], "rc") != "0") tfail++
    }
    for (id in tnet) printf "  %-16s net %s, pruned %s\n", id, h(tnet[id]), h(tpr[id])
    printf "  runs with nonzero rc: %d\n", tfail + 0
}
' "$f"
