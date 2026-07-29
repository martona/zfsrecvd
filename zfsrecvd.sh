#!/usr/bin/env bash
# zfsrecvd protocol 2.0 receiver. socat (see listen.sh) spawns one instance
# per TLS connection; stdin/stdout are the socket, stderr goes to the journal.
#
# A connection is one *session*: any number of sequential TREE exchanges,
# each being a client manifest, our state dump back, a series of
# SEND/RESUME/ABORT transfers, and an ENDTREE (prune + stamp). Streams are
# multiplexed over the socket with no framing; that works because bash's
# read consumes bytes one at a time (never past its newline), zfs recv
# stops at the stream's END record without needing EOF, and the client is
# forbidden from writing anything after a stream until it sees our result
# line. See PROTOCOL.md for the full contract; v1.1 is not supported (the
# fleet upgrades atomically via deploy.sh).

set -euo pipefail
set -f                       # never glob; we word-split protocol input
source /etc/zfsrecvd/cfgparser.sh

# Field grammars from PROTOCOL.md §3. Anything outside these charsets is
# rejected before it reaches a zfs command line.
RE_DATASET='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
RE_SNAP='^[A-Za-z0-9._-]+$'
RE_SIZE='^([0-9]+|-)$'

log() { echo "$*" >&2; }          # to the journal
out() { printf '%s\n' "$*"; }     # to the client (the socket)

# Protocol errors are always session-fatal: tell the client if we still
# can, log why, and drop the connection.
proto_err() {
    out "ERR proto $*"
    log "protocol error: $*"
    exit 1
}

#
# ---- 1. authenticate CN -----------------------------------------------------
#
# The transport already verified the client cert against our CA; what's
# left is learning the CN it carried and checking the whitelist. The CN
# also names the client's namespace: everything it sends lands under
# recv_root/<CN>/.
#   socat transport:   OPENSSL-LISTEN verify=1 exports the CN in the env.
#   haproxy transport: haproxy terminated TLS and prepended a PROXY
#     protocol v2 header with the CN it extracted from the verified cert;
#     pp2_read_cn consumes exactly that header (fail-closed ladder, see
#     pp2.sh) and leaves the session bytes untouched on stdin.
if [[ "$transport" == "haproxy" ]]; then
    source /etc/zfsrecvd/pp2.sh
    if ! pp2_read_cn; then
        log "ERROR: bad/missing PROXY protocol header on the plaintext port (direct dial? haproxy misconfig?); dropping"
        exit 1
    fi
    cn="$PP2_CN"
else
    cn="${SOCAT_OPENSSL_X509_COMMONNAME-}"
    if [[ -z "$cn" ]]; then
        log "ERROR: TLS CN missing; socat not started with OPENSSL-LISTEN verify=1?"
        exit 1
    fi
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
# The fleet upgrades in one deploy, so this is a sanity check rather than a
# negotiation: any 2.x client is answered with the highest version we speak
# (2.0); everything else is logged and dropped.
IFS= read -r -t 30 hello || { log "ERROR: no version line"; exit 1; }
if ! [[ "$hello" =~ ^zfsrecvd2\.[0-9]+$ ]]; then
    log "ERROR: unsupported version '$hello'"
    exit 1
fi
out "OK zfsrecvd2.0"

#
# ---- session state ----------------------------------------------------------
#
declare -A made_parents=()   # parents already ensured this session (skip re-create)
base_ready=""                # dest_base existence confirmed (lazy, once)
tree_root=""                 # source-side root of the TREE currently in progress
received=()                  # dest datasets received this tree; stamped at ENDTREE

# Is a client-supplied path inside the tree announced by TREE? This is the
# scope check that keeps a session from writing outside its own subtree.
in_tree() {
    [[ "$1" == "$tree_root" || "$1" == "$tree_root"/* ]]
}

# Make sure recv_root/<CN> exists (unmounted). Created without -p on
# purpose: -p would ignore -o mountpoint=none, and a missing recv_root is
# an operator error we want to surface, not paper over.
ensure_base() {
    if [[ -z "$base_ready" ]]; then
        zfs list -H -o name "$dest_base" >/dev/null 2>&1 \
            || zfs create -o mountpoint=none "$dest_base" 2>/dev/null \
            || return 1
        base_ready=1
    fi
}

# Make sure the destination parent of a dataset exists, so that
# `zfs recv -e <parent>` has somewhere to land. Nonzero only when even the
# CN base can't be created (caller turns that into ERR refused).
ensure_parent() {
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
# Everything we know about the tree, in two zfs invocations total: one
# snapshot listing (globally creation-sorted, which keeps each dataset's
# sub-list creation-sorted too) grouped into HAVE lines, and one property
# scan for pending resume TOKENs. Paths are translated to source-relative
# so both sides talk in the same names.
emit_state() {
    local dest_tree="${dest_base}/${tree_root}"
    local pfx="${dest_base}/"
    local have_lines token_lines
    have_lines=$(zfs list -H -r -t snapshot -s creation -o name "$dest_tree" 2>/dev/null | awk -v pfx="$pfx" '
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
    ') || true
    token_lines=$(zfs get -H -r -t filesystem,volume -o name,value receive_resume_token "$dest_tree" 2>/dev/null \
        | awk -v pfx="$pfx" '
            $2 != "-" && index($1, pfx) == 1 {
                printf "TOKEN %s %s\n", substr($1, length(pfx) + 1), $2
            }
        ') || true
    [[ -n "$have_lines" ]] && printf '%s\n' "$have_lines"
    [[ -n "$token_lines" ]] && printf '%s\n' "$token_lines"
    out ""
    local nh=0 nt=0
    [[ -n "$have_lines" ]] && nh=$(wc -l <<<"$have_lines")
    [[ -n "$token_lines" ]] && nt=$(wc -l <<<"$token_lines")
    log "state sent: $nh datasets known, $nt pending resumes"
}

#
# ---- transfers --------------------------------------------------------------
#
# SEND <ds> <from|-> <to> <est|->: validate, answer GO, hand the socket to
# zfs recv. Refusals (scope, missing recv_root) happen before GO and leave
# the session healthy. A recv failure after the stream started is fatal to
# the session: we can't know how much of the unframed stream was consumed,
# so resynchronization is impossible (PROTOCOL.md §7) -- the client
# reconnects and the interrupted dataset comes back via its resume token.
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
        if [[ "$est" == "-" ]]; then
            log "received $ds ($from -> $to)"
        else
            log "received $ds ($from -> $to, ~$est bytes)"
        fi
    else
        rc=$?
        detail=$(tail -n 1 "$errf" | tr -dc '[:print:]' | cut -c 1-500)
        rm -f -- "$errf"
        out "ERR recv $ds ${detail:-zfs recv exit $rc}"
        log "recv FAILED for $ds: ${detail:-exit $rc}; closing session"
        exit 1
    fi
}

# RESUME <ds> <est|->: like SEND, but the client continues an interrupted
# stream from our receive_resume_token, so recv targets the dataset itself
# rather than the -e parent form.
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

# ABORT <ds>: discard our pending resume state (zfs recv -A) because the
# client can no longer satisfy the token (its side of the resume was
# pruned). No stream is involved, so failure here is a refusal, not a
# session-killer -- the byte stream is still in sync either way.
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
        out "ERR refused $ds abort failed: ${detail:-unknown}"
        log "recv -A failed for $ds: ${detail:-unknown}"
    fi
}

#
# ---- pruning + stamping (at ENDTREE) ----------------------------------------
#
# Keep the newest keep_count snapshots whose names match a prune-prefix,
# per dataset, across the whole tree in one listing pass. Snapshots outside
# the prefixes (manual ones, foreign tools') are never touched.
prune_tree() {
    local dest_tree="${dest_base}/${tree_root}"
    local snap ds name prefix matched extra i pruned=0
    declare -A psnaps=()     # dataset -> space-joined prunable snaps, oldest first
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
            if zfs destroy "${list[i]}" 2>/dev/null; then
                pruned=$(( pruned + 1 ))
            else
                log "WARNING: failed to prune ${list[i]}"
            fi
        done
    done
    if (( pruned > 0 )); then
        log "pruned $pruned snapshots under $dest_tree"
    fi
}

# ENDTREE: prune, then stamp everything received this tree with
# zfsrecvd:last-recv (marks the dataset as ours + records freshness; this
# is the foundation the future orphan GC reads). One zfs set for the whole
# batch, with a per-dataset fallback in case a zfs version dislikes
# multiple targets.
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
    log "tree $tree_root complete: ${#received[@]} received this session"
    out "OK ENDTREE"
}

#
# ---- TREE handler -----------------------------------------------------------
#
# Read the client's manifest (validated but, in 2.0, only logged), send the
# state dump, then serve transfers until ENDTREE hands control back to the
# session loop.
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
# Between trees a session idles here; a client that goes quiet for two
# minutes is dropped (so-keepalive on the socket reaps dead peers too).
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
