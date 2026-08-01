#!/usr/bin/env bash
# Retention grid selector (PROTOCOL.md §22). Pure function, no zfs:
# source this and pipe ONE dataset's prunable snapshot NAMES (one per
# line, any order) into retain_destroy; it emits the names to DESTROY.
#
#   retain_destroy "hourly=48 daily=30 weekly=8 monthly=12" < names
#
# Semantics (owner-agreed 2026-07-29):
# - Buckets are UTC calendar periods, keyed straight off the timestamp
#   embedded in the snapshot name (stevedore-YYYY-MM-DD-HHMMZ): hour, day,
#   ISO week (%G-W%V), month. Names ARE the clock; creation dates are
#   never consulted, so decisions are deterministic and testable from a
#   name list alone.
# - The representative of a period is its FIRST snapshot (stable once
#   the period closes). bucket=N keeps the representatives of the N
#   newest periods THAT HAVE snapshots -- gaps don't burn budget.
# - The newest snapshot overall is ALWAYS kept (it is the incremental
#   frontier), even when it is not any period's representative.
# - Keep set = union across buckets; everything else is emitted.
#
# Fail-safe posture: this function DESTROYS BY OMISSION ONLY -- anything
# it cannot reason about is kept silently: names without a parseable
# timestamp are never emitted, an empty/garbled spec emits nothing, and
# an unknown spec token disables the whole call (stderr note). Wrong
# output here is "kept too much", never "history gone".

retain_destroy() {   # $1 = spec; names on stdin; destroy list on stdout
    local spec="$1"
    local kv b n
    local -A want=( [hourly]=0 [daily]=0 [weekly]=0 [monthly]=0 )
    for kv in $spec; do
        b="${kv%%=*}"; n="${kv#*=}"
        if [[ -z "${want[$b]+x}" || ! "$n" =~ ^[0-9]+$ ]]; then
            echo "retain: unknown spec token '$kv'; keeping everything" >&2
            return 0
        fi
        want[$b]=$n
    done

    # ingest + parse; unparseable names are simply never candidates
    local name y mo d hhmm ts
    local names=() stamps=()
    while IFS= read -r name; do
        [[ -n "$name" ]] || continue
        if [[ "$name" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})([0-9]{2})Z$ ]]; then
            y="${BASH_REMATCH[1]}"; mo="${BASH_REMATCH[2]}"
            d="${BASH_REMATCH[3]}"; hhmm="${BASH_REMATCH[4]}${BASH_REMATCH[5]}"
            names+=( "$name" )
            stamps+=( "$y-$mo-$d-$hhmm" )
        fi
    done
    local total=${#names[@]}
    (( total > 0 )) || return 0

    # sort ascending by timestamp (name order == time order for equal
    # prefixes; the stamp is what we sort on, so mixed prefixes work)
    local order i
    order=$(for (( i = 0; i < total; i++ )); do
        printf '%s %s\n' "${stamps[i]}" "$i"
    done | sort | awk '{print $2}')

    # first-of-period representatives, periods in ascending order
    local -A rep_h=() rep_d=() rep_w=() rep_m=() wkcache=()
    local keys_h=() keys_d=() keys_w=() keys_m=()
    local idx key day wk newest=""
    for i in $order; do
        ts="${stamps[i]}"; name="${names[i]}"
        newest="$name"
        key="${ts:0:13}"                       # YYYY-MM-DD-HH
        if [[ -z "${rep_h[$key]:-}" ]]; then rep_h[$key]="$name"; keys_h+=( "$key" ); fi
        day="${ts:0:10}"                       # YYYY-MM-DD
        if [[ -z "${rep_d[$day]:-}" ]]; then rep_d[$day]="$name"; keys_d+=( "$day" ); fi
        if (( want[weekly] > 0 )); then
            if [[ -z "${wkcache[$day]:-}" ]]; then
                wkcache[$day]=$(date -u -d "$day" +%G-W%V 2>/dev/null) || wkcache[$day]="$day"
            fi
            wk="${wkcache[$day]}"
            if [[ -z "${rep_w[$wk]:-}" ]]; then rep_w[$wk]="$name"; keys_w+=( "$wk" ); fi
        fi
        key="${ts:0:7}"                        # YYYY-MM
        if [[ -z "${rep_m[$key]:-}" ]]; then rep_m[$key]="$name"; keys_m+=( "$key" ); fi
    done

    # keep = newest-N periods' representatives per bucket + the frontier
    local -A keep=()
    keep[$newest]=1
    local nk
    nk=${#keys_h[@]}
    for (( i = nk - want[hourly];  i < nk; i++ )); do (( i >= 0 )) && keep[${rep_h[${keys_h[i]}]}]=1; done
    nk=${#keys_d[@]}
    for (( i = nk - want[daily];   i < nk; i++ )); do (( i >= 0 )) && keep[${rep_d[${keys_d[i]}]}]=1; done
    nk=${#keys_w[@]}
    for (( i = nk - want[weekly];  i < nk; i++ )); do (( i >= 0 )) && keep[${rep_w[${keys_w[i]}]}]=1; done
    nk=${#keys_m[@]}
    for (( i = nk - want[monthly]; i < nk; i++ )); do (( i >= 0 )) && keep[${rep_m[${keys_m[i]}]}]=1; done

    for i in $order; do
        name="${names[i]}"
        [[ -n "${keep[$name]:-}" ]] || printf '%s\n' "$name"
    done
}
