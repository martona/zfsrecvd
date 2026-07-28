#!/bin/bash

# run_indented <prefix> <command> [args...]
#
# Executes the command and prepends the prefix to every line of its combined
# stdout+stderr. Records are split on \r\n, \r, or \n -- longest match
# first, so a CRLF pair is ONE separator; splitting on the characters
# individually would yield an empty record between \r and \n, which came
# out as a spurious prefix-only line after every completed pv display.
# Bare \r stays a separator of its own, so progress bars keep refreshing
# in place with the prefix intact. The fflush() is
# load-bearing: stdio only flushes on \n, and pv's in-place updates end in a
# bare \r -- without an explicit flush they sit in gawk's buffer until the
# transfer ends, which is why an earlier version of this appeared to produce
# no output at all.
#
# ZFSRECVD_INDENT tells descendants how many columns of prefix will be glued
# onto their lines: anything that sizes output to the terminal width (pv, see
# send.sh) must shrink by that amount, or the line exceeds the terminal
# width, wraps, and \r-refreshes land on fresh rows instead of overwriting.
#
# Returns the command's exit status, not the pipeline's.

if command -v gawk >/dev/null 2>&1; then
    run_indented() {
        local prefix=$1; shift
        ZFSRECVD_INDENT=$(( ${ZFSRECVD_INDENT:-0} + ${#prefix} )) \
        "$@" 2>&1 | gawk -v p="$prefix" '
            BEGIN       { RS = "\r\n|\r|\n"; ORS = "" }
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
