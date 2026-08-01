# stevedore

A crummy but long-fat-pipe-friendly fleet replication tool for zfs.
(Formerly `zfsrecvd`; a stevedore loads cargo between ships and docks —
bulk transfer, reliably, no glamour.)

## Why

SSH doesn't cut it when it comes to sending ZFS snapshots to faraway lands. OpenSSH's baked-in 2MB window limit was already too small in 2007 when it was finally increased from 64K. There are alternatives such as [hpn-ssh](https://github.com/rapier1/hpn-ssh) but that is a whole-ass SSH fork, something I'm not brave enough for.

Stock OpenSSH caps long fat pipes very harshly. As an example, I'm getting 500Mbits on a 30ms link to the nearest AWS datacenter through its small window. With OpenSSH replaced, I get 4Gbits.

None of this is rocket science, nor do I expect it to interest anyone, but I do use it a lot. Github is an ideal place to clone it from, and there's no point in keeping it private either.

## What

One config file (`/etc/stevedore/fleet.conf`) describes the fleet: hosts, jobs (source, tree, destination), retention. A run provisions everything else itself:

- per-run CA and certs (minted at run start, discarded at teardown — the private keys never leave the hosts they're minted on),
- per-run listeners as transient systemd units (socat mTLS, or haproxy terminating TLS with PROXY-protocol identity for higher throughput),
- the scripts themselves, shipped to every participant each run — participants are stateless; onboarding a sender is one job row, an ssh key, and three packages.

The wire protocol (v2.1) runs one TLS session per dataset tree, multiplexes raw zfs streams over it with no framing, exchanges snapshot+GUID manifests so lineage collisions are refused or renamed aside instead of clobbered, and reports per-dataset results in-band. Retention is a global grid (hourlies on senders, a deep hourly/daily/weekly/monthly grid on receivers), replication cursors (bookmarks) survive total source snapshot loss, and orphan/receiver-only detection runs warn-only with long grace clocks. `runs.jsonl` is the ledger; `steve report` renders it.

Requirements: `zfsutils-linux socat pv openssl` (plus `haproxy` for that transport), systemd, and ssh with passwordless sudo between the orchestrator and participants.

## Install

Only the orchestrator needs an install; participants get everything per run.

```
git clone <this repo> && cd stevedore
sudo bash stevedore.sh install
```

That places the scripts in `/usr/local/lib/stevedore/`, links `/usr/local/bin/steve`, creates `/etc/stevedore/` and the ledger in `/var/lib/stevedore/` (owned by you, not root). Then write `/etc/stevedore/fleet.conf` and you're done:

```
[options]
user       marton
port       5299
transport  haproxy

[retention]
source        hourly=24
destination   hourly=48 daily=30 weekly=8 monthly=12

[hosts]
bergamo     recv=tank/recv   data=bergamo.lan
ec2backup   recv=ebs/recv    data=ec2-zfsrecv   ec2=i-0401...   cadence=24h

[jobs]
jupiter     nvmetank      bergamo
bergamo     tank/backup   ec2backup
```

## Use

```
steve run              # one fleet run
steve run --check      # plan preview, nothing provisioned
steve report           # what happened, trends, gc findings
steve check            # doctor
steve help             # the rest
```

Manual single-dataset sends still work outside orchestrated runs (`/usr/local/lib/stevedore/stevedore-send.sh <ds[@snap]> <host>`), sending the newest snapshot if none is given, incremental against the newest common ancestor, `-R -w` (raw — encrypted datasets replicate without their keys ever being present on the receiver).

## Tuning

Required on both ends to get the best out of your TCP stack:

```
sudo tee -a /etc/sysctl.d/99-fast-long-fat-tcp.conf << EOF
# allow 64 MB socket buffers
net.core.rmem_max=67108864
net.core.wmem_max=67108864

# bump autotune ceilings (min / default / max)
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864

# better window ramp
net.ipv4.tcp_congestion_control=bbr
EOF
sudo sysctl --system
```

## Updating

`git pull && sudo bash stevedore.sh install` on the orchestrator. The next fleet run ships the new scripts to every participant; version skew within a run is impossible.

## Uninstall

`sudo steve uninstall` (code only; `--purge` also removes config and ledger).
