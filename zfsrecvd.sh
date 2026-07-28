#!/usr/bin/env bash
# zfsrecvd protocol 2.0 receiver. One process per connection (spawned by
# socat, see listen.sh), serving one session: any number of TREE exchanges,
# each with SEND/RESUME/ABORT transfers, ended by ENDTREE. See PROTOCOL.md
# for the contract; v1.1 is not supported (fleet upgrades atomically).
#
# stdin/stdout are the TLS socket; stderr goes to the journal.

set -euo pipefail
set -f
source /etc/zfsrecvd/cfgparser.sh

RE_DATASET='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
RE_SNAP='^[A-Za-z0-9._-]+$'
RE_SIZE='^([0-9]+|-)$'

log() { echo "$*" >&2; }
out() { printf '%s\n' "$*"; }

proto_err() {
    out "ERR proto $*"
    log "protocol error: $*"
    exit 1
}

#
# ---- 1. authenticate CN -----------------------------------------------------
#
cn="${SOCAT_OPENSSL_X509_COMMONNAME-}"
if [[ -z "$cn" ]]; then
    log "ERROR: TLS CN missing; socat not started with OPENSSL-LISTEN verify=1?"
    exit 1
fi
if ! [[ " ${allowed_hosts[*]} " == *" $cn "* ]]; then
    log "ERROR: CN '$cn' not authorized"
    exit 1
fi
safe_cn=${cn//[^[:alnum:]._-]/_}
dest_base="${recv_root}/${safe_cn}"
log "session from: $safe_cn"

#
# ---- 2. version sanity check ------------------------------------------------
#
IFS= read -r -t 30 hello || { log "ERROR: no version line"; exit 1; }
if ! [[ "$hello" =~ ^zfsrecvd2\.[0-9]+$ ]]; then
    log "ERROR: unsupported version '$hello'"
    exit 1
fi
out "OK zfsrecvd2.0"

#
# ---- session state ----------------------------------------------------------
#
declare -A made_parents=()
base_ready=""
tree_root=""
received=()

in_tree() {
    [[ "$1" == "$tree_root" || "$1" == "$tree_root"/* ]]
}

ensure_base() {
    if [[ -z "$base_ready" ]]; then
        zfs list -H -o name "$dest_base" >/dev/null 2>&1 \
            || zfs create -o mountpoint=none "$dest_base" 2>/dev/null \
            || return 1
        base_ready=1
    fi
}

ensure_parent() {   # $1 = source dataset path; nonzero if base can't be made
    local parent="${dest_base}/$1"
    parent="${parent%/*}"
    if [[ -n "${made_parents[$parent]:-}" ]]; then
        return 0
    fi
    ensure_base || return 1
    # -o is ignored with -p (hence ensure_base above); pre-existing is fine.
    zfs create -p "$parent" 2>/dev/null || true
    made_parents[$parent]=1
}

#
# ---- state dump -------------------------------------------------------------
#
emit_state() {
    local dest_tree="${dest_base}/${tree_root}"
    local pfx="${dest_base}/"
    zfs list -H -r -t snapshot -s creation -o name "$dest_tree" 2>/dev/null | awk -v pfx="$pfx" '
        {
            at = index($0, "@"); if (at == 0) next
            ds = substr($0, 1, at - 1)
            sn = substr($0, at + 1)
            if (index(ds, pfx) != 1) next
            rel = substr(ds, length(pfx) + 1)
            if (rel in acc) acc[rel] = acc[rel] "," sn
            else { order[++n] = rel; acc[rel] = sn }
        }
        END { for (i = 1; i <= n; i++) printf "HAVE %s %s\n", order[i], acc[order[i]] }
    ' || true
    zfs get -H -r -t filesystem,volume -o name,value receive_resume_token "$dest_tree" 2>/dev/null \
        | awk -v pfx="$pfx" '
            $2 != "-" && index($1, pfx) == 1 {
                printf "TOKEN %s %s\n", substr($1, length(pfx) + 1), $2
            }
        ' || true
    out ""
}

#
# ---- transfers --------------------------------------------------------------
#
do_send() {
    local _ ds from to est extra
    read -r _ ds from to est extra <<<"$1"
    [[ -n "$est" && -z "$extra" ]] || proto_err "SEND arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "SEND dataset"
    [[ "$from" == "-" || "$from" =~ $RE_SNAP ]] || proto_err "SEND from-snap"
    [[ "$to" =~ $RE_SNAP ]] || proto_err "SEND to-snap"
    [[ "$est" =~ $RE_SIZE ]] || proto_err "SEND size"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        log "refused SEND $ds (outside $tree_root)"
        return 0
    fi
    if ! ensure_parent "$ds"; then
        out "ERR refused $ds cannot create destination (recv_root '$recv_root' missing?)"
        log "refused SEND $ds: cannot create destination under $dest_base"
        return 0
    fi
    local parent="${dest_base}/${ds}"
    parent="${parent%/*}"
    out "GO"
    local errf rc detail
    errf=$(mktemp)
    if zfs recv -s -u -F -e -x canmount "$parent" 2>"$errf"; then
        rm -f -- "$errf"
        out "OK $ds"
        received+=( "${dest_base}/${ds}" )
        log "received $ds ($from -> $to)"
    else
        rc=$?
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf"
        out "ERR recv $ds ${detail:-zfs recv exit $rc}"
        log "recv FAILED for $ds: ${detail:-exit $rc}; closing session"
        exit 1
    fi
}

do_resume() {
    local _ ds est extra
    read -r _ ds est extra <<<"$1"
    [[ -n "$est" && -z "$extra" ]] || proto_err "RESUME arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "RESUME dataset"
    [[ "$est" =~ $RE_SIZE ]] || proto_err "RESUME size"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        return 0
    fi
    out "GO"
    local errf rc detail
    errf=$(mktemp)
    if zfs recv -s "${dest_base}/${ds}" 2>"$errf"; then
        rm -f -- "$errf"
        out "OK $ds"
        received+=( "${dest_base}/${ds}" )
        log "resumed $ds"
    else
        rc=$?
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf"
        out "ERR recv $ds ${detail:-zfs recv exit $rc}"
        log "resume FAILED for $ds: ${detail:-exit $rc}; closing session"
        exit 1
    fi
}

do_abort() {
    local _ ds extra
    read -r _ ds extra <<<"$1"
    [[ -n "$ds" && -z "$extra" ]] || proto_err "ABORT arity"
    [[ "$ds" =~ $RE_DATASET ]] || proto_err "ABORT dataset"
    if ! in_tree "$ds"; then
        out "ERR refused $ds not under session tree"
        return 0
    fi
    local errf detail
    errf=$(mktemp)
    if zfs recv -A "${dest_base}/${ds}" 2>"$errf"; then
        rm -f -- "$errf"
        out "OK $ds"
        log "aborted pending resume on $ds"
    else
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf"
        # no stream was involved, so the session is still in sync
        out "ERR refused $ds abort failed: ${detail:-unknown}"
        log "recv -A failed for $ds: ${detail:-unknown}"
    fi
}

#
# ---- pruning + stamping (at ENDTREE) ----------------------------------------
#
prune_tree() {
    local dest_tree="${dest_base}/${tree_root}"
    local snap ds name prefix matched extra i
    declare -A psnaps=()
    local order=()
    while IFS= read -r snap; do
        ds="${snap%@*}"
        name="${snap#*@}"
        matched=""
        for prefix in "${prune_prefixes[@]}"; do
            if [[ "$name" == "$prefix"* ]]; then
                matched=1
                break
            fi
        done
        [[ -n "$matched" ]] || continue
        if [[ -z "${psnaps[$ds]:-}" ]]; then
            order+=( "$ds" )
        fi
        psnaps[$ds]="${psnaps[$ds]:-}${psnaps[$ds]:+ }$snap"
    done < <(zfs list -H -r -t snapshot -s creation -o name "$dest_tree" 2>/dev/null || true)
    local list=()
    for ds in "${order[@]}"; do
        read -r -a list <<<"${psnaps[$ds]}"
        extra=$(( ${#list[@]} - keep_count ))
        for (( i = 0; i < extra; i++ )); do
            log "pruning ${list[i]}"
            zfs destroy "${list[i]}" 2>/dev/null || log "WARNING: failed to prune ${list[i]}"
        done
    done
}

do_endtree() {
    prune_tree
    if [[ ${#received[@]} -gt 0 ]]; then
        local stamp
        stamp="zfsrecvd:last-recv=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        if ! zfs set "$stamp" "${received[@]}" 2>/dev/null; then
            local d
            for d in "${received[@]}"; do
                zfs set "$stamp" "$d" 2>/dev/null || true
            done
        fi
        log "stamped ${#received[@]} datasets"
    fi
    out "OK ENDTREE"
}

#
# ---- TREE handler -----------------------------------------------------------
#
handle_tree() {   # $1 = tree root, $2 = target snapname
    tree_root="$1"
    received=()
    local snap="$2" line d manifest_count=0 ended=""
    while IFS= read -r -t 120 line; do
        if [[ -z "$line" ]]; then
            ended=1
            break
        fi
        if [[ "$line" =~ ^DS\ ([A-Za-z0-9._/-]+)$ ]]; then
            d="${BASH_REMATCH[1]}"
            in_tree "$d" || proto_err "manifest dataset outside tree: $d"
            manifest_count=$(( manifest_count + 1 ))
        else
            proto_err "bad manifest line"
        fi
    done
    [[ -n "$ended" ]] || proto_err "eof/timeout in manifest"
    log "TREE $tree_root@$snap ($manifest_count datasets in manifest)"
    out "OK TREE"
    emit_state

    while true; do
        IFS= read -r -t 300 line || { log "eof/idle in transfer loop"; exit 1; }
        case "$line" in
            SEND\ *)   do_send "$line" ;;
            RESUME\ *) do_resume "$line" ;;
            ABORT\ *)  do_abort "$line" ;;
            ENDTREE)   do_endtree; return 0 ;;
            *)         proto_err "unexpected in transfer loop" ;;
        esac
    done
}

#
# ---- session loop -----------------------------------------------------------
#
while true; do
    IFS= read -r -t 120 line || { log "session idle/eof; closing"; exit 0; }
    case "$line" in
        TREE\ *)
            read -r _ troot tsnap textra <<<"$line"
            [[ -n "${tsnap:-}" && -z "${textra:-}" ]] || proto_err "TREE arity"
            [[ "$troot" =~ $RE_DATASET ]] || proto_err "TREE root"
            [[ "$tsnap" =~ $RE_SNAP ]] || proto_err "TREE snap"
            handle_tree "$troot" "$tsnap"
            ;;
        BYE)
            log "session ended cleanly"
            exit 0
            ;;
        *)
            proto_err "expected TREE or BYE"
            ;;
    esac
done
