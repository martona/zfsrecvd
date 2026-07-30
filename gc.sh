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

# Env-overridable so the machinery can be WATCHED without waiting a
# month -- safe to turn all the way down precisely because this build
# cannot destroy anything:
#   sudo env ZFSRECVD_GC_CAND_DAYS=0 ZFSRECVD_GC_GRACE_DAYS=0 \
#       ZFSRECVD_CONF=/etc/zfsrecvd/run/<id>/run.conf /etc/zfsrecvd/gc.sh
CAND_DAYS="${ZFSRECVD_GC_CAND_DAYS:-30}"    # behind-siblings threshold
GRACE_DAYS="${ZFSRECVD_GC_GRACE_DAYS:-90}"  # observation -> eligible

now=$(date -u +%s)
say() { echo "GC:   $*"; }

while IFS= read -r cnroot; do
    [[ "$cnroot" != "$recv_root" ]] || continue
    cn="${cnroot##*/}"

    # one listing pass: name + both stamps for the whole CN subtree
    newest=0
    n_cand=0
    n_unst=0
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
            && say "$cnroot: no stamps anywhere; nothing assessed (pre-v2 or foreign subtree)"
        unset lr osince
        continue
    fi

    for ds in "${dss[@]}"; do
        if [[ -z "${lr[$ds]:-}" ]]; then
            # never stamped: report true leaves only
            has_stamped_child=""
            for other in "${dss[@]}"; do
                if [[ -n "${lr[$other]:-}" && "$other" == "$ds"/* ]]; then
                    has_stamped_child=1
                    break
                fi
            done
            if [[ -z "$has_stamped_child" ]]; then
                n_unst=$(( n_unst + 1 ))
                say "$ds: UNSTAMPED -- never received under zfsrecvd"
            fi
            continue
        fi
        behind=$(( (newest - lr[$ds]) / 86400 ))
        if (( behind >= CAND_DAYS )); then
            n_cand=$(( n_cand + 1 ))
            if [[ -z "${osince[$ds]:-}" ]]; then
                stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
                zfs set "zfsrecvd:orphan-since=$stamp" "$ds" 2>/dev/null || true
                say "$ds: ORPHAN CANDIDATE -- ${behind}d behind siblings; eligible for reclaim in ${GRACE_DAYS}d (warn-only build, nothing is destroyed)"
            else
                oe=$(date -u -d "${osince[$ds]}" +%s 2>/dev/null) || oe=$now
                left=$(( GRACE_DAYS - (now - oe) / 86400 ))
                if (( left > 0 )); then
                    say "$ds: ORPHAN CANDIDATE -- ${behind}d behind siblings; eligible in ${left}d"
                else
                    say "$ds: RECLAIM-ELIGIBLE -- ${behind}d behind siblings; grace expired (warn-only build, NOT destroyed)"
                fi
            fi
        elif [[ -n "${osince[$ds]:-}" ]]; then
            zfs inherit zfsrecvd:orphan-since "$ds" 2>/dev/null || true
            say "$ds: recovered -- receiving again; orphan clock cleared"
        fi
    done
    # client summary (owner report wishlist): one line per CN, always
    say "$cnroot: ${#dss[@]} datasets, newest recv $(( (now - newest) / 86400 ))d ago, ${n_cand} orphan candidate(s), ${n_unst} unstamped"
    unset lr osince
done < <(zfs list -H -d 1 -t filesystem -o name "$recv_root" 2>/dev/null || true)

exit 0
