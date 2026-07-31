#!/usr/bin/env bash
# Orphan GC, WARN-ONLY build (PROTOCOL.md §22), manifest era: since 2.1
# the SERVER owns every clock (zfsrecvd.sh stamps orphan-since on
# manifest-absent datasets and unknown-since on receiver-only snapshots
# at ENDTREE, and clears both on reappearance). This script is READ-ONLY
# -- it renders the clocks. Runs ON a receiver against its recv_root;
# fleetrun invokes it after each run.
#
# Timeline per clocked item (owner 2026-07-31: "60+30, not 90+30"):
#   stamp+0 ......... GC-TRACK inventory line (jsonl; report --gc-debug)
#   stamp+WARN_DAYS . console warning with the countdown
#   stamp+GRACE_DAYS  RECLAIM-ELIGIBLE -- still warn-only, NO destroy
#                     path exists in this build ("reclamation never the
#                     first mention").
# Also lists never-stamped LEAF datasets (the "old crap"; containers
# whose descendants are stamped are scaffolding and stay quiet).
# A dead or paused sender sends no manifests, so nothing new is ever
# stamped during total silence -- and the future destroy path must
# re-verify against the LATEST manifest before acting.
#
# Exit 0 always.

set -euo pipefail
source /etc/zfsrecvd/cfgparser.sh

# Env-overridable so the machinery can be WATCHED without waiting months
# -- safe to turn all the way down precisely because this build cannot
# destroy anything:
#   sudo env ZFSRECVD_GC_WARN_DAYS=0 ZFSRECVD_GC_GRACE_DAYS=0 \
#       ZFSRECVD_CONF=/etc/zfsrecvd/run/<id>/run.conf /etc/zfsrecvd/gc.sh
WARN_DAYS="${ZFSRECVD_GC_WARN_DAYS:-60}"    # stamp -> console warnings
GRACE_DAYS="${ZFSRECVD_GC_GRACE_DAYS:-90}"  # stamp -> reclaim-eligible

now=$(date -u +%s)
say() { echo "GC:   $*"; }
# Track lines are INVENTORY, not warnings: every item carrying a reclaim
# clock (orphan-since dataset, unknown-since snapshot), ripe or not,
# every run. fleetrun keeps them off the console and harvests them into
# the run record; report.sh renders them only under --gc-debug
# (owner 2026-07-31). A direct gc.sh invocation prints them plainly --
# that IS the debug view.
track() { echo "GC-TRACK: $*"; }
quiet_cns=0
quiet_ds=0

while IFS= read -r cnroot; do
    [[ "$cnroot" != "$recv_root" ]] || continue
    cn="${cnroot##*/}"

    # one listing pass: name + both stamps for the whole CN subtree
    newest=0
    n_cand=0
    n_warn=0
    n_unst=0
    declare -A lr=() osince=()
    dss=()
    declare -A _seen=()
    while IFS=$'\t' read -r ds prop val src; do
        [[ "$ds" != "$cnroot" ]] || continue
        if [[ -z "${_seen[$ds]:-}" ]]; then
            _seen[$ds]=1
            dss+=( "$ds" )
        fi
        # User properties INHERIT: a freshly-stamped parent cloaks every
        # unstamped child if effective values are trusted (bit the
        # owner's deep test dataset on day one). local and received are
        # stamps (received = per-dataset, survives pool migrations --
        # §17 corollary); inherited values are nothing.
        [[ "$src" == "local" || "$src" == "received" ]] || continue
        if [[ "$prop" == "zfsrecvd:last-recv" && "$val" != "-" ]]; then
            e=$(date -u -d "$val" +%s 2>/dev/null) || e=0
            lr[$ds]=$e
            (( e > newest )) && newest=$e
        elif [[ "$prop" == "zfsrecvd:orphan-since" && "$val" != "-" ]]; then
            osince[$ds]="$val"
        fi
    done < <(zfs get -H -r -t filesystem,volume \
        -o name,property,value,source zfsrecvd:last-recv,zfsrecvd:orphan-since \
        "$cnroot" 2>/dev/null)

    if (( newest == 0 )); then
        [[ ${#dss[@]} -gt 0 ]] \
            && say "$cnroot: no stamps anywhere; nothing assessed (pre-v2 or foreign subtree)"
        unset lr osince _seen
        continue
    fi

    for ds in "${dss[@]}"; do
        if [[ -z "${lr[$ds]:-}" && -z "${osince[$ds]:-}" ]]; then
            # never stamped with anything: report true leaves only
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
        # clocked dataset: the server stamped it manifest-absent; render
        # its phase. Quiet on the console until WARN_DAYS -- its time
        # has not come -- but always in the track inventory.
        [[ -n "${osince[$ds]:-}" ]] || continue
        oe=$(date -u -d "${osince[$ds]}" +%s 2>/dev/null) || oe=$now
        oage=$(( (now - oe) / 86400 ))
        left=$(( GRACE_DAYS - oage ))
        n_cand=$(( n_cand + 1 ))
        if (( oage >= GRACE_DAYS )); then
            n_warn=$(( n_warn + 1 ))
            say "$ds: RECLAIM-ELIGIBLE -- absent at source since ${osince[$ds]}; grace expired (warn-only build, NOT destroyed)"
            track "$ds: orphan-since ${osince[$ds]}; grace expired"
        elif (( oage >= WARN_DAYS )); then
            n_warn=$(( n_warn + 1 ))
            say "$ds: ABSENT AT SOURCE -- since ${osince[$ds]}; eligible for reclaim in ${left}d"
            track "$ds: orphan-since ${osince[$ds]}; eligible in ${left}d"
        else
            track "$ds: orphan-since ${osince[$ds]}; eligible in ${left}d"
        fi
    done
    # receiver-only snapshots: unknown-since clocks set by the 2.1
    # receiver at ENDTREE (PROTOCOL.md §15b). Same phase rendering as
    # datasets: tracked from day 0, console-warned from WARN_DAYS.
    while IFS=$'\t' read -r sn val; do
        [[ -n "$sn" && "$val" != "-" ]] || continue
        ue=$(date -u -d "$val" +%s 2>/dev/null) || ue=$now
        uage=$(( (now - ue) / 86400 ))
        uleft=$(( GRACE_DAYS - uage ))
        if (( uage >= GRACE_DAYS )); then
            n_warn=$(( n_warn + 1 ))
            say "$sn: RECLAIM-ELIGIBLE -- receiver-only since $val; grace expired (warn-only build, NOT destroyed)"
            track "$sn: unknown-since $val; grace expired"
        elif (( uage >= WARN_DAYS )); then
            n_warn=$(( n_warn + 1 ))
            say "$sn: RECEIVER-ONLY -- since $val; eligible for reclaim in ${uleft}d"
            track "$sn: unknown-since $val; eligible in ${uleft}d"
        else
            track "$sn: unknown-since $val; eligible in ${uleft}d"
        fi
    done < <(zfs get -H -r -s local,received -t snapshot -o name,value zfsrecvd:unknown-since "$cnroot" 2>/dev/null || true)

    # client summary: per-CN line only when there is something WARNED
    # about (owner: all-zero lines "elevate to noise", and un-warned
    # clocks are deliberately quiet -- their time has not come); healthy
    # CNs roll up into one all-quiet line at the end.
    age=$(( (now - newest) / 86400 ))
    if (( n_warn > 0 || n_unst > 0 || age >= 1 )); then
        say "$cnroot: ${#dss[@]} datasets, newest recv ${age}d ago, ${n_cand} orphan candidate(s), ${n_unst} unstamped"
    else
        quiet_cns=$(( quiet_cns + 1 ))
        quiet_ds=$(( quiet_ds + ${#dss[@]} ))
    fi
    unset lr osince _seen
done < <(zfs list -H -d 1 -t filesystem -o name "$recv_root" 2>/dev/null || true)

if (( quiet_cns > 0 )); then
    say "all quiet: $quiet_cns client(s), $quiet_ds datasets, everything fresh"
fi

exit 0
