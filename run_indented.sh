#!/bin/bash

# run_indented <prefix> <command> [args...]
#
# Executes the command and prepends the prefix to every line of its combined
# stdout+stderr. Records are split on both \n and \r, so pv-style progress
# bars keep refreshing in place with the prefix intact. The fflush() is
# load-bearing: stdio only flushes on \n, and pv's in-place updates end in a
# bare \r -- without an explicit flush they sit in gawk's buffer until the
# transfer ends, which is why an earlier version of this appeared to produce
# no output at all.
#
# Returns the command's exit status, not the pipeline's.

if command -v gawk >/dev/null 2>&1; then
    run_indented() {
        local prefix=$1; shift
        "$@" 2>&1 | gawk -v p="$prefix" '
            BEGIN       { RS = "[\r\n]"; ORS = "" }
            { printf "%s%s%s", p, $0, RT; fflush() }
        '
        return "${PIPESTATUS[0]}"
    }
else
    # No gawk (RT is a gawk-ism): degrade to running the command unprefixed.
    run_indented() {
        shift
        "$@"
    }
fi
