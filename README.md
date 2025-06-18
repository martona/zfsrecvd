# zfsrecvd
A crummy but long-fat-pipe-friendly replication helper for zfs

## Why

SSH doesn't cut it when it comes to sending ZFS snapshots to faraway lands. OpenSSH's baked-in 2MB window limit was already too small in 2007 when it was finally increased from 64K. There are alternatives such as [hpn-ssh]([https://github.com/rapier1/hpn-ssh) but that is a whole-ass SSH fork, something I'm not brave enough for.

Stock OpenSSH caps long fat pipes very harshly. As an example, I'm getting 500Mbits on a 30ms link to the nearest AWS datacenter through its small window. With OpenSSH replaced, I get 4Gbits. 

None of this is rocket science, nor do I expect it to interest anyone, but I do use it a lot. Github is an ideal place to clone it from, and there's no point in keeping it private either.

## What

Instead of SSH, I use Wireguard for linking the EC2 instance to my network, then `socat` to move the zfs-send between boxes. There's a recv-side script (auto-spawned by a systemd service) that handles mutual TLS authentication, and a send-side script to assist with finding common snapshot ancestors, then they both hand traffic over to `zfs send` and `zfs recv`.

Requirements:

```
pv
zfsutils-linux
socat
```

The setup also assumes systemd.

## Install

Create `/etc/zfsrecvd` and copy the contents of this directory there. 

On the receive side: 

- Edit `/etc/zfsrecvd/zfsrecvd.conf` to set up the mTLS auth whitelist and specify the dataset that will be the root for whatever `zfs recv` will store.
- Provide `server.pem`, `server.key` and `ca.pem`. The `server.*` files are for the server's SSL certificiate (leaf cert and private key), `ca.pem` is used to verify the client-provided certificate.
- Run `systemctl link /etc/zfsrecvd/zfsrecvd.service && systemctl enable --now zfsrecvd.service`. 

On the send side:

- Provide `client.pem`, `client.key` and `ca.pem`. The latter is used to verify the server's cert. The `client.*` files are the sender's identity. The CN field in the client cert has to be in the receive-side's auth whitelist. It's best to make this the same as the hostname. The recv-side script will also create a zfs dataset under the root that matches this name, and will create all datasets sent by this host under it, e.g. `tank/recv/hostname/tank/mydata@20250618`.

This is also required on both ends to get the best out of your TCP stack:

```
sudo tee -a /etc/sysctl.d/99-fast-long-fat-tcp.conf << EOF
# allow 64 MB socket buffers
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

## Uninstall

Just undo the above.

## Use

Invoke `/etc/zfsrecvd/send.sh` with the first parameter being the snapshot you're sending, the second parameter being the resolvable network name of the recv-side box, e.g.:

```
/etc/zfsrecvd/send.sh tank/mydata@20250618 ec2-zfsrecv
```

If you omit the snapshot specification, the script will find the most recent snapshot for the dataset. In other words, this works too:

```
/etc/zfsrecvd/send.sh tank/mydata ec2-zfsrecv
```

In either case, the script will determine the most recent snapshot that exists on both systems, and perform an incremental send against it. If no such snapshot exists, a full send will be performed.

Send is always done with the -R and -w flags; the main implication of the first is that it's recursive and includes child datasets. The -w (raw) flag is most commonly used with encrypted snapshots, which mine are.

