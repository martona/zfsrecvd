#!/usr/bin/env bash
# Orphan GC (PROTOCOL.md §22), manifest era: since 2.1 the SERVER owns
# every clock (stevedore-recv.sh stamps orphan-since on manifest-absent
# datasets and unknown-since on receiver-only snapshots at ENDTREE, and
# clears both on reappearance). This script renders the clocks -- and,
# ONLY under --destroy (fleet.conf [options] gc-destroy on), reclaims
# what they have proven. Runs ON a receiver against its recv_root;
# fleetrun invokes it after each run.
#
# Timeline per clocked item (owner 2026-07-31: "60+30, not 90+30"):
#   stamp+0 ......... GC-TRACK inventory line (jsonl; report --gc-debug)
#   stamp+WARN_DAYS . console warning with the countdown
#   stamp+GRACE_DAYS  RECLAIM-ELIGIBLE; destroyed only under --destroy
#                     AND only when re-confirmed (below)
#
# The destroy gate, per §22 ("a stamp alone never suffices" -- this is
# the manifest-era translation of re-verify-against-the-latest-report):
#   datasets:  orphan-since expired AND the CN's newest last-recv
#              postdates the stamp by >= WARN_DAYS -- live sessions
#              kept confirming the absence for that long (a session
#              would have CLEARED the stamp on reappearance). Destroyed
#              BOTTOM-UP, depth-descending, `zfs destroy -r` each, and
#              only when EVERY live descendant is itself eligible:
#              stamps age per-dataset, and -r must never take a
#              non-eligible child along.
#   snapshots: unknown-since expired AND the PARENT dataset's last-recv
#              postdates the stamp by >= WARN_DAYS; grid-prefix names
#              are the retention grid's business, never GC's.
# Total-silence safety is intrinsic on both paths: a dead or paused
# sender refreshes no last-recv, so the margin never accrues and
# nothing dies on stale evidence.
#
# Also lists never-stamped LEAF datasets (the "old crap"; containers
# whose descendants are stamped are scaffolding and stay quiet).
#
# Exit 0 always.

set -euo pipefail
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stevedore-cfgparser.sh"

# Env-overridable so the machinery can be WATCHED without waiting months
# -- safe to turn all the way down WITHOUT --destroy, where nothing can
# be destroyed:
#   sudo env STEVEDORE_GC_WARN_DAYS=0 STEVEDORE_GC_GRACE_DAYS=0 \
#       STEVEDORE_CONF=/run/stevedore/<id>/run.conf \
#       /usr/local/lib/stevedore/stevedore-gc.sh
WARN_DAYS="${STEVEDORE_GC_WARN_DAYS:-60}"    # stamp -> console warnings
GRACE_DAYS="${STEVEDORE_GC_GRACE_DAYS:-90}"  # stamp -> reclaim-eligible

destroy=""
if [[ "${1:-}" == "--destroy" ]]; then
    destroy=1
fi

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
    declare -A delig=() blocked=() sewhy=()
    selig=()
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
        if [[ "$prop" == "stevedore:last-recv" && "$val" != "-" ]]; then
            e=$(date -u -d "$val" +%s 2>/dev/null) || e=0
            lr[$ds]=$e
            (( e > newest )) && newest=$e
        elif [[ "$prop" == "stevedore:orphan-since" && "$val" != "-" ]]; then
            osince[$ds]="$val"
        fi
    done < <(zfs get -H -r -t filesystem,volume \
        -o name,property,value,source stevedore:last-recv,stevedore:orphan-since \
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
                say "$ds: UNSTAMPED -- never received under stevedore"
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
            # Re-confirmation gate (§22: a stamp alone never suffices):
            # the CN's newest last-recv must postdate the stamp by
            # WARN_DAYS -- live sessions kept confirming the absence
            # (a reappearance would have CLEARED the stamp). Stale
            # evidence (paused/dead sender) destroys nothing, ever.
            if [[ -z "$destroy" ]]; then
                say "$ds: RECLAIM-ELIGIBLE -- absent at source since ${osince[$ds]}; grace expired (destroy flag off; NOT destroyed)"
            elif (( newest - oe >= WARN_DAYS * 86400 )); then
                delig[$ds]="${osince[$ds]}"   # outcome printed by the destroy pass
            else
                say "$ds: RECLAIM-ELIGIBLE -- absent at source since ${osince[$ds]}; grace expired; NOT destroyed (absence not re-confirmed by sessions since the stamp)"
            fi
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
            # parent's last-recv carries the re-confirmation: the
            # dataset kept receiving (and kept not re-mentioning this
            # guid) for WARN_DAYS past the stamp
            pds="${sn%@*}"
            pe="${lr[$pds]:-0}"
            gridsnap=""
            for pfx in "${prune_prefixes[@]}"; do
                if [[ "${sn##*@}" == "$pfx"* ]]; then
                    gridsnap=1
                    break
                fi
            done
            if [[ -z "$destroy" ]]; then
                say "$sn: RECLAIM-ELIGIBLE -- receiver-only since $val; grace expired (destroy flag off; NOT destroyed)"
            elif [[ -n "$gridsnap" ]]; then
                # belt: stamps never land on grid snaps, but the grid's
                # snapshots are the retention grid's business, never GC's
                say "$sn: RECLAIM-ELIGIBLE but grid-prefixed; the grid owns it, NOT destroyed (stray stamp?)"
            elif (( pe - ue >= WARN_DAYS * 86400 )); then
                selig+=( "$sn" )
                sewhy[$sn]="$val"
            else
                say "$sn: RECLAIM-ELIGIBLE -- receiver-only since $val; grace expired; NOT destroyed (dataset not re-confirmed by sessions since the stamp)"
            fi
            track "$sn: unknown-since $val; grace expired"
        elif (( uage >= WARN_DAYS )); then
            n_warn=$(( n_warn + 1 ))
            say "$sn: RECEIVER-ONLY -- since $val; eligible for reclaim in ${uleft}d"
            track "$sn: unknown-since $val; eligible in ${uleft}d"
        else
            track "$sn: unknown-since $val; eligible in ${uleft}d"
        fi
    done < <(zfs get -H -r -s local,received -t snapshot -o name,value stevedore:unknown-since "$cnroot" 2>/dev/null || true)

    # ---- destroy pass (--destroy only) ---------------------------------
    # Snapshots first (independent, cheap), then datasets BOTTOM-UP:
    # depth-descending, `zfs destroy -r` each, skip already-gone. A
    # dataset dies only when every live descendant is itself eligible --
    # stamps age per-dataset, and -r must never take a non-eligible
    # child along (§22, owner-specified).
    n_destroyed=0
    if [[ -n "$destroy" ]]; then
        for sn in "${selig[@]:-}"; do
            [[ -n "$sn" ]] || continue
            if zfs destroy "$sn" 2>/dev/null; then
                say "$sn: DESTROYED -- receiver-only since ${sewhy[$sn]}; grace expired, absence re-confirmed"
                n_destroyed=$(( n_destroyed + 1 ))
            else
                say "$sn: WARNING -- destroy failed (hold or clone?); still eligible"
            fi
        done
        for cand in "${!delig[@]}"; do
            for other in "${dss[@]}"; do
                if [[ "$other" == "$cand"/* && -z "${delig[$other]:-}" ]]; then
                    blocked[$cand]=1
                    say "$cand: eligible but NOT destroyed -- descendant $other is not eligible (-r must never take it along)"
                    break
                fi
            done
        done
        while read -r _ cand; do
            [[ -n "${cand:-}" && -z "${blocked[$cand]:-}" ]] || continue
            # a deeper eligible sibling-tree destroy cannot have taken
            # us, but the check is one cheap list either way
            zfs list -H -o name "$cand" >/dev/null 2>&1 || continue
            if zfs destroy -r "$cand" 2>/dev/null; then
                say "$cand: DESTROYED (-r) -- orphan-since ${delig[$cand]}; grace expired, absence re-confirmed"
                n_destroyed=$(( n_destroyed + 1 ))
            else
                say "$cand: WARNING -- destroy failed (hold, clone, or busy?); still eligible"
            fi
        done < <(
            for cand in "${!delig[@]}"; do
                d="${cand//[^\/]/}"
                printf '%d %s\n' "${#d}" "$cand"
            done | sort -rn -k1,1
        )
        if (( n_destroyed > 0 )); then
            say "$cnroot: reclaimed $n_destroyed item(s) this pass"
        fi
    fi

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
    unset lr osince _seen delig blocked sewhy
done < <(zfs list -H -d 1 -t filesystem -o name "$recv_root" 2>/dev/null || true)

if (( quiet_cns > 0 )); then
    say "all quiet: $quiet_cns client(s), $quiet_ds datasets, everything fresh"
fi

exit 0
