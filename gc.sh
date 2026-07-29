#!/usr/bin/env bash
# Orphan GC, WARN-ONLY build (PROTOCOL.md §22). Runs ON a receiver
# against its recv_root; fleetrun invokes it after each run and prints
# the output in every mode (these are summary-class lines, unlike prune
# chatter).
#
# What it does -- and ALL it does; there is NO destroy path in this
# build, deliberately ("reclamation never the first mention"):
#   * finds datasets stale RELATIVE to their CN siblings, stamps
#     zfsrecvd:orphan-since on first sight (the grace clock starts at
#     OBSERVATION, never retroactively -- a missing stamp implies no
#     age), and warns with the countdown;
#   * clears orphan-since when a dataset starts receiving again;
#   * lists never-stamped LEAF datasets (owner ask 2026-07-29: surface
#     the "old crap"; containers whose descendants are stamped are
#     scaffolding and stay quiet).
# Total silence is never a candidate: if everything under a CN is stale,
# nothing is RELATIVELY stale -- a dead or paused sender must never cost
# its receiver-side history.
#
# Exit 0 always.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

CAND_DAYS=30      # behind-siblings threshold to become a candidate
GRACE_DAYS=90     # observation -> reclaim-eligible (destroy NOT built)

now=$(date -u +%s)
say() { echo "GC: $*"; }

while IFS= read -r cnroot; do
    [[ "$cnroot" != "$recv_root" ]] || continue
    cn="${cnroot##*/}"

    # one listing pass: name + both stamps for the whole CN subtree
    newest=0
    declare -A lr=() osince=()
    dss=()
    while IFS=$'\t' read -r ds v_lr v_os; do
        [[ "$ds" != "$cnroot" ]] || continue
        dss+=( "$ds" )
        if [[ "$v_lr" != "-" ]]; then
            e=$(date -u -d "$v_lr" +%s 2>/dev/null) || e=0
            lr[$ds]=$e
            (( e > newest )) && newest=$e
        fi
        [[ "$v_os" != "-" ]] && osince[$ds]="$v_os"
    done < <(zfs list -H -r -t filesystem,volume \
        -o name,zfsrecvd:last-recv,zfsrecvd:orphan-since "$cnroot" 2>/dev/null)

    if (( newest == 0 )); then
        [[ ${#dss[@]} -gt 0 ]] \
            && say "[$cn] no stamps anywhere; nothing assessed (pre-v2 or foreign subtree)"
        unset lr osince
        continue
    fi

    for ds in "${dss[@]}"; do
        # CN-relative: the [cn] prefix already names the namespace
        rel="${ds#"$cnroot"/}"
        if [[ -z "${lr[$ds]:-}" ]]; then
            # never stamped: report true leaves only
            has_stamped_child=""
            for other in "${dss[@]}"; do
                if [[ -n "${lr[$other]:-}" && "$other" == "$ds"/* ]]; then
                    has_stamped_child=1
                    break
                fi
            done
            [[ -n "$has_stamped_child" ]] \
                || say "[$cn] UNSTAMPED: $rel (never received under zfsrecvd; old crap?)"
            continue
        fi
        behind=$(( (newest - lr[$ds]) / 86400 ))
        if (( behind >= CAND_DAYS )); then
            if [[ -z "${osince[$ds]:-}" ]]; then
                stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                zfs set "zfsrecvd:orphan-since=$stamp" "$ds" 2>/dev/null || true
                say "[$cn] ORPHAN CANDIDATE: $rel (${behind}d behind siblings; eligible for reclaim in ${GRACE_DAYS}d -- warn-only build, nothing is destroyed)"
            else
                oe=$(date -u -d "${osince[$ds]}" +%s 2>/dev/null) || oe=$now
                left=$(( GRACE_DAYS - (now - oe) / 86400 ))
                if (( left > 0 )); then
                    say "[$cn] ORPHAN CANDIDATE: $rel (${behind}d behind siblings; eligible in ${left}d)"
                else
                    say "[$cn] RECLAIM-ELIGIBLE: $rel (${behind}d behind siblings; grace expired -- warn-only build, NOT destroyed)"
                fi
            fi
        elif [[ -n "${osince[$ds]:-}" ]]; then
            zfs inherit zfsrecvd:orphan-since "$ds" 2>/dev/null || true
            say "[$cn] recovered: $rel (receiving again; orphan clock cleared)"
        fi
    done
    unset lr osince
done < <(zfs list -H -d 1 -t filesystem -o name "$recv_root" 2>/dev/null || true)

exit 0
