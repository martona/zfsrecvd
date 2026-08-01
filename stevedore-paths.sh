#!/usr/bin/env bash
# The stevedore installation layout -- the single path-constants block
# (PROTOCOL.md §24). Everything sources this from its own directory, so a
# repo checkout, the VM rig's ~/zfsrecvd-src, and the installed tree all
# work identically for LOCAL sibling calls. Cross-HOST command lines must
# splice $STEVE_LIB instead: the remote layout is always the installed
# one, and env does not cross ssh (§17 corollary).

STEVE_LIB="/usr/local/lib/stevedore"   # impl scripts; shipped per run
STEVE_BIN="/usr/local/bin/steve"       # user entry: symlink into STEVE_LIB
STEVE_ETC="/etc/stevedore"             # config ONLY (no perma-certs post-F)
STEVE_RUN="/run/stevedore"             # per-identity run bundles; tmpfs is
                                       # a feature: reboot kills listener
                                       # and trust material together
STEVE_VAR="/var/lib/stevedore"         # ledger (runs.jsonl) + ec2 debt;
                                       # install chowns it to the
                                       # orchestrator user

# The complete impl-file set: what `steve install` places in STEVE_LIB and
# what fleetrun ships to every participant each run (stateless fleet, §18).
# One list so the two can never drift.
STEVE_FILES=(
    stevedore.sh
    stevedore-paths.sh
    stevedore-cfgparser.sh
    stevedore-fleetparser.sh
    stevedore-ec2helpers.sh
    stevedore-run-indented.sh
    stevedore-pp2.sh
    stevedore-retain.sh
    stevedore-sendtree.sh
    stevedore-send.sh
    stevedore-listen.sh
    stevedore-recv.sh
    stevedore-gc.sh
    stevedore-orchestrate.sh
    stevedore-fleetrun.sh
    stevedore-report.sh
    stevedore-unlock-replica.sh
)
