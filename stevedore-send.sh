#!/usr/bin/env bash
# Manual single-dataset entry point: a one-dataset protocol-2.0 session.
#
# Usage:   send.sh <dataset[@snap]> <remote_host>
# Example: send.sh tank/outer/inner/actual@snap2025-06-18 backup-box
#
# Without @snap, the dataset's newest snapshot is sent. All the real logic
# lives in stevedore-sendtree.sh (see PROTOCOL.md); this just restricts it
# to one dataset, non-recursive.
exec "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/stevedore-sendtree.sh" --single "$@"
