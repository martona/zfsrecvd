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
function wmax(w, v) { return (length(v) > w ? length(v) : w) }
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
    ok = 0; bad = 0; cad = 0; unr = 0
    for (i = jstart[r]; i <= jend[r]; i++) {
        st = g(J[i], "state"); rc = g(J[i], "rc")
        if (st == "done" && rc == "0") { ok++; continue }
        if (st == "cadence") {
            if (g(J[i], "why") ~ /^source unreachable/) unr++; else cad++
            continue
        }
        bad++
        fd = g(J[i], "failed_ds")
        printf "  FAIL  [%s] %s -> [%s]  (%s rc=%s) %s%s\n", \
            g(J[i], "src"), g(J[i], "tree"), g(J[i], "dst"), st, rc, \
            g(J[i], "why"), (fd != "" ? "; datasets: " fd : "")
    }
    printf "  jobs: %d ok, %d not ok", ok, bad
    if (cad > 0) printf ", %d within cadence", cad
    if (unr > 0) printf ", %d source offline", unr
    printf "\n"

    # receivers table: numbers right-aligned, widths from content
    rn = 0; line = rline[r]
    while (match(line, "\\{\"id\":\"[^\"]*\",\"before\":[^}]*\\}")) {
        rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        rn++
        rid[rn]  = g(rec, "id")
        rnet[rn] = h(g(rec, "after") - g(rec, "before"))
        rpr[rn]  = h(g(rec, "pruned") + 0)
        rav[rn]  = h(g(rec, "avail") + 0)
    }
    if (rn > 0) {
        w1 = length("receiver"); w2 = length("net"); w3 = length("pruned"); w4 = length("avail")
        for (i = 1; i <= rn; i++) {
            w1 = wmax(w1, rid[i]);  w2 = wmax(w2, rnet[i])
            w3 = wmax(w3, rpr[i]);  w4 = wmax(w4, rav[i])
        }
        fmt = "  %-" w1 "s  %" w2 "s  %" w3 "s  %" w4 "s\n"
        print ""
        printf fmt, "receiver", "net", "pruned", "avail"
        for (i = 1; i <= rn; i++) printf fmt, rid[i], rnet[i], rpr[i], rav[i]
    }

    # sources table: per-tree used / avail
    sn = 0; line = rline[r]
    while (match(line, "\\{\"id\":\"[^\"]*\",\"tree\":[^}]*\\}")) {
        rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        sn++
        sid[sn] = g(rec, "id")
        str[sn] = g(rec, "tree")
        sus[sn] = h(g(rec, "used") + 0)
        sav[sn] = h(g(rec, "avail") + 0)
    }
    if (sn > 0) {
        w1 = length("source"); w2 = length("tree"); w3 = length("used"); w4 = length("avail")
        for (i = 1; i <= sn; i++) {
            w1 = wmax(w1, sid[i]);  w2 = wmax(w2, str[i])
            w3 = wmax(w3, sus[i]);  w4 = wmax(w4, sav[i])
        }
        fmt = "  %-" w1 "s  %-" w2 "s  %" w3 "s  %" w4 "s\n"
        print ""
        printf fmt, "source", "tree", "used", "avail"
        for (i = 1; i <= sn; i++) printf fmt, sid[i], str[i], sus[i], sav[i]
    }

    # gc findings (fleetrun harvests gc.sh stdout per receiver into the
    # record; summary-class lines, few by design)
    gn = 0; line = rline[r]
    while (match(line, "\\{\"id\":\"[^\"]*\",\"gc\":\"[^\"]*\"\\}")) {
        rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
        gn++
        gid[gn] = g(rec, "id"); gtxt[gn] = g(rec, "gc")
    }
    if (gn > 0) {
        print ""
        for (i = 1; i <= gn; i++) printf "  gc [%s] %s\n", gid[i], gtxt[i]
    }

    # trend: per-receiver sums over the window, first-seen order
    lo = (runs - NRUNS + 1 < 1 ? 1 : runs - NRUNS + 1)
    tn = 0
    for (x = lo; x <= runs; x++) {
        line = rline[x]
        while (match(line, "\\{\"id\":\"[^\"]*\",\"before\":[^}]*\\}")) {
            rec = substr(line, RSTART, RLENGTH); line = substr(line, RSTART + RLENGTH)
            id = g(rec, "id")
            if (!(id in tnet)) { tn++; tord[tn] = id; tnet[id] = 0; tpr[id] = 0 }
            tnet[id] += g(rec, "after") - g(rec, "before")
            tpr[id]  += g(rec, "pruned") + 0
        }
        if (g(rline[x], "rc") != "0") tfail++
    }
    print ""
    printf "trend (last %d run(s)):\n", runs - lo + 1
    if (tn > 0) {
        w1 = length("receiver"); w2 = length("net"); w3 = length("pruned")
        for (i = 1; i <= tn; i++) {
            id = tord[i]; thn[i] = h(tnet[id]); thp[i] = h(tpr[id])
            w1 = wmax(w1, id); w2 = wmax(w2, thn[i]); w3 = wmax(w3, thp[i])
        }
        fmt = "  %-" w1 "s  %" w2 "s  %" w3 "s\n"
        printf fmt, "receiver", "net", "pruned"
        for (i = 1; i <= tn; i++) printf fmt, tord[i], thn[i], thp[i]
    }
    printf "  runs with nonzero rc: %d\n", tfail + 0
}
' "$f"
