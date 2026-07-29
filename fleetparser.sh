#!/usr/bin/env bash
# Parser for fleet.conf -- the Final Shape's single source of truth, read
# ONLY by the orchestrator (fleetrun.sh). Schema: PROTOCOL.md Part II §18.
#
# Source this, then call:  fleet_parse /etc/zfsrecvd/fleet.conf
# On success the fleet_* globals below are populated; on ANY problem it
# exits 78 (EX_CONFIG) with "file:line: message". Validation is loud and
# fatal on purpose: this file is hand-edited and spreadsheet-pasted, and a
# typo must die at parse time, not at provisioning time.
#
# Globals:
#   fleet_opt_user fleet_opt_port fleet_opt_workers fleet_opt_transport   [options] w/ defaults
#   fleet_ret_source fleet_ret_destination     raw bucket strings, reserved for D
#   fleet_host_ssh[] _data[] _recv[] _ec2[] _bind[]     assoc by identity, sparse
#   fleet_job_src[] fleet_job_tree[] fleet_job_dest[]   parallel arrays, one row per job
#   fleet_sources[] fleet_receivers[] fleet_participants[]   derived, deduped,
#                                                            first-seen order
# Helpers:
#   fleet_ssh_dest <id>  -> user@addr for ssh (defaults applied)
#   fleet_data <id>      -> data-plane dial name (defaults to the identity)

FLEET_RE_IDENT='^[A-Za-z0-9._-]+$'
FLEET_RE_TREE='^[A-Za-z0-9._][A-Za-z0-9._/-]*$'
FLEET_RE_NUM='^[0-9]+$'

fleet_opt_user=""
fleet_opt_port=""
fleet_opt_workers=""
fleet_opt_transport=""
fleet_ret_source=""
fleet_ret_destination=""
declare -A fleet_host_ssh fleet_host_data fleet_host_recv fleet_host_ec2 fleet_host_bind
declare -A _fleet_host_seen _fleet_job_seen
fleet_job_src=()
fleet_job_tree=()
fleet_job_dest=()
fleet_sources=()
fleet_receivers=()
fleet_participants=()

# Uses the caller's (fleet_parse's) $cfg and $nr via dynamic scoping.
_fleet_fatal() {
    echo "${cfg}:${nr}: $*" >&2
    exit 78
}

_fleet_opt_line() {
    (( $# == 2 )) || _fleet_fatal "options lines are 'key value'"
    case "$1" in
        user)    [[ "$2" =~ $FLEET_RE_IDENT ]] || _fleet_fatal "bad user '$2'"
                 fleet_opt_user="$2" ;;
        port)    [[ "$2" =~ $FLEET_RE_NUM ]] || _fleet_fatal "port must be numeric"
                 fleet_opt_port="$2" ;;
        workers) [[ "$2" =~ $FLEET_RE_NUM ]] || _fleet_fatal "workers must be numeric"
                 fleet_opt_workers="$2" ;;
        transport) [[ "$2" == "socat" || "$2" == "haproxy" ]] \
                     || _fleet_fatal "transport must be 'socat' or 'haproxy'"
                 fleet_opt_transport="$2" ;;
        *)       _fleet_fatal "unknown option '$1'" ;;
    esac
}

_fleet_ret_line() {
    local scope="$1"
    shift
    (( $# >= 1 )) || _fleet_fatal "retention line needs at least one bucket"
    local kv
    for kv in "$@"; do
        [[ "$kv" =~ ^(hourly|daily|weekly|monthly)=[0-9]+$ ]] \
            || _fleet_fatal "bad retention bucket '$kv' (hourly|daily|weekly|monthly=N)"
    done
    case "$scope" in
        source)      fleet_ret_source="$*" ;;
        destination) fleet_ret_destination="$*" ;;
        *)           _fleet_fatal "retention scope must be 'source' or 'destination'" ;;
    esac
}

_fleet_host_line() {
    local id="$1"
    shift
    [[ "$id" =~ $FLEET_RE_IDENT ]] || _fleet_fatal "bad host identity '$id'"
    [[ -n "${_fleet_host_seen[$id]:-}" ]] && _fleet_fatal "duplicate host '$id'"
    _fleet_host_seen[$id]=1
    # A vanilla host (all defaults) should simply have no entry at all.
    (( $# >= 1 )) || _fleet_fatal "host '$id' has no attributes; vanilla hosts need no entry"
    local kv k v
    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        [[ "$kv" == *=* && -n "$v" ]] || _fleet_fatal "host attribute must be key=value: '$kv'"
        case "$k" in
            ssh)  fleet_host_ssh[$id]="$v" ;;
            data) [[ "$v" == *:* ]] && _fleet_fatal "per-host data port is reserved; use [options] port"
                  [[ "$v" =~ $FLEET_RE_IDENT ]] || _fleet_fatal "bad data name '$v'"
                  fleet_host_data[$id]="$v" ;;
            recv) [[ "$v" =~ $FLEET_RE_TREE ]] || _fleet_fatal "bad recv dataset '$v'"
                  fleet_host_recv[$id]="$v" ;;
            ec2)  fleet_host_ec2[$id]="$v" ;;
            bind) fleet_host_bind[$id]="$v" ;;
            *)    _fleet_fatal "unknown host attribute '$k'" ;;
        esac
    done
}

_fleet_job_line() {
    if (( $# != 3 )); then
        local w
        for w in "$@"; do
            [[ "$w" == via=* ]] && _fleet_fatal "via= is reserved for the relay phase (R); not supported yet"
        done
        _fleet_fatal "job rows are 'source tree dest' (exactly 3 columns)"
    fi
    local s="$1" t="$2" d="$3"
    [[ "$s" =~ $FLEET_RE_IDENT ]] || _fleet_fatal "bad source '$s'"
    [[ "$t" =~ $FLEET_RE_TREE ]]  || _fleet_fatal "bad tree '$t'"
    [[ "$d" =~ $FLEET_RE_IDENT ]] || _fleet_fatal "bad dest '$d'"
    [[ "$s" == "$d" ]] && _fleet_fatal "source == dest for tree '$t'"
    local key="$s|$t|$d"
    [[ -n "${_fleet_job_seen[$key]:-}" ]] && _fleet_fatal "duplicate job: $s $t $d"
    _fleet_job_seen[$key]=1
    fleet_job_src+=( "$s" )
    fleet_job_tree+=( "$t" )
    fleet_job_dest+=( "$d" )
}

fleet_parse() {
    local -
    set -f                       # we word-split config lines; never glob them
    local cfg="$1" nr=0 section="" line
    [[ -r "$cfg" ]] || { nr=0; _fleet_fatal "cannot read file"; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        nr=$(( nr + 1 ))
        line=${line%%#*}
        line=${line//$'\r'/}
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        if [[ $line =~ ^\[(.*)\]$ ]]; then
            section="${BASH_REMATCH[1]}"
            case "$section" in
                options|retention|hosts|jobs) ;;
                *) _fleet_fatal "unknown section [$section]" ;;
            esac
            continue
        fi
        case "$section" in
            "")        _fleet_fatal "content before the first section" ;;
            options)   _fleet_opt_line  $line ;;   # unquoted: word-split the columns
            retention) _fleet_ret_line  $line ;;
            hosts)     _fleet_host_line $line ;;
            jobs)      _fleet_job_line  $line ;;
        esac
    done < "$cfg"

    # ---- defaults + cross-row validation + derivations -----------------
    nr="EOF"
    [[ -z "$fleet_opt_user" ]] && fleet_opt_user="$(id -un)"
    [[ -z "$fleet_opt_port" ]] && fleet_opt_port=5299
    [[ -z "$fleet_opt_workers" ]] && fleet_opt_workers=8
    [[ -z "$fleet_opt_transport" ]] && fleet_opt_transport="socat"
    (( ${#fleet_job_src[@]} > 0 )) || _fleet_fatal "no [jobs] defined"
    local i s d
    declare -A _seen_src=() _seen_recv=() _seen_part=()
    for (( i = 0; i < ${#fleet_job_src[@]}; i++ )); do
        s="${fleet_job_src[i]}"
        d="${fleet_job_dest[i]}"
        # Sources without a [hosts] entry are legal (vanilla senders), so a
        # source typo can't be caught here; a dest typo always can, because
        # every dest must be declared with recv=.
        [[ -n "${fleet_host_recv[$d]:-}" ]] \
            || _fleet_fatal "dest '$d' has no recv= ([hosts] entry missing, or a typo in a job row)"
        if [[ -z "${_seen_src[$s]:-}" ]]; then
            _seen_src[$s]=1
            fleet_sources+=( "$s" )
        fi
        if [[ -z "${_seen_recv[$d]:-}" ]]; then
            _seen_recv[$d]=1
            fleet_receivers+=( "$d" )
        fi
    done
    for s in "${fleet_sources[@]}" "${fleet_receivers[@]}"; do
        if [[ -z "${_seen_part[$s]:-}" ]]; then
            _seen_part[$s]=1
            fleet_participants+=( "$s" )
        fi
    done
}

fleet_ssh_dest() {
    local v="${fleet_host_ssh[$1]:-}"
    if [[ -z "$v" ]]; then
        printf '%s@%s\n' "$fleet_opt_user" "$1"
    elif [[ "$v" == *@* ]]; then
        printf '%s\n' "$v"
    else
        printf '%s@%s\n' "$fleet_opt_user" "$v"
    fi
}

fleet_data() {
    printf '%s\n' "${fleet_host_data[$1]:-$1}"
}

# fleet_ret_bucket <raw scope string> <bucket> -> count, or "" if absent.
# e.g. fleet_ret_bucket "$fleet_ret_destination" hourly
fleet_ret_bucket() {
    local -
    set -f
    local kv
    for kv in $1; do
        if [[ "$kv" == "$2="* ]]; then
            printf '%s\n' "${kv#*=}"
            return 0
        fi
    done
    printf '\n'
}
