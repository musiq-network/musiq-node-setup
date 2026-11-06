# MusIQ Node Setup

Install the **MusIQ node agent** on a Linux server. The agent proves your node is
running by sending a signed **heartbeat** to the MusIQ Network. Each day your node
checks in, its license earns **Node DAO Participation Rewards**, recorded on the
Gnodi blockchain and claimable from your MusIQ dashboard.

Most members use a hosting partner, who runs this for you. You can also host your
own node with the steps below.

## Install

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main/install.sh)
```

You'll be asked for your **license key** (`MSQ-XXXX-XXXX-XXXX`). It's shown on
**Dashboard → My Nodes** at musiqnetwork.com.

The installer:

1. checks for `curl`, `jq` and OpenSSL with Ed25519 support (installs what's missing),
2. generates this node's **signing key** (`/opt/musiq-agent/node.key`, never leaves the machine),
3. **activates** your license with that key,
4. installs a **systemd timer** that sends a heartbeat every 6 hours (only one per day
   counts; the extra check-ins mean a short outage never costs a day), and
5. sends the first heartbeat.

### Requirements

| | |
|---|---|
| OS | Linux with systemd — Ubuntu 20.04+ or Debian 11+ recommended |
| OpenSSL | 1.1.1 or newer (Ed25519) |
| Network | Outbound HTTPS (443) to `musiqnetwork.com` |
| Access | root / sudo |
| Resources | Minimal — the agent is a short shell script run a few times a day |

## Check it's working

```bash
systemctl list-timers musiq-agent.timer     # next scheduled heartbeat
journalctl -u musiq-agent -n 20             # recent heartbeats
sudo systemctl start musiq-agent            # send one now
```

A healthy log line looks like `Heartbeat recorded for day 123.` Your dashboard's
**Rewards** page shows each license's last check-in.

## Move to a new server / rotate the key

Run the installer again on the new machine. It generates a new key and re-activates
the license; the old machine's heartbeats stop being accepted. One license runs on
one node at a time.

## Uninstall

```bash
sudo bash install.sh --uninstall
```

Your license and any rewards are unaffected.

## For hosting partners

Use **`musiq-host.sh`** to run many nodes on one server: one systemd timer checks in
every node on the machine, each with its own signing key. Nodes are activated by
**license id** with your host API key, so you never need members' license keys.

```bash
curl -fsSLO https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main/musiq-host.sh
chmod +x musiq-host.sh
sudo MUSIQ_HOST_API_KEY=mnh_... ./musiq-host.sh setup        # config + timer (installs /usr/local/bin/musiq-host)
sudo musiq-host activate <licenseId> [<licenseId> ...]       # add nodes
sudo musiq-host activate-file ids.txt                        # or one license id per line
sudo musiq-host status                                       # every node and its last heartbeat
sudo musiq-host remove <licenseId>                           # stop hosting a node
```

| Variable (for `setup`) | Purpose |
|---|---|
| `MUSIQ_HOST_API_KEY` | Your host API key (`mnh_…`) |
| `MUSIQ_API_BASE` | API base (default `https://musiqnetwork.com`; dev: `https://dev.musiqnetwork.com`) |
| `MUSIQ_BYPASS` | Dev only: the access-bypass secret |
| `MUSIQ_PARALLEL` | Heartbeats sent at once (default 16) |
| `MUSIQ_SCHEDULE` | systemd `OnCalendar` for heartbeats (default every 6 h) |

Layout: `/opt/musiq-host/host.env` (config, mode 600) and
`/opt/musiq-host/nodes/<licenseId>/node.key` (one Ed25519 key per node, mode 600).
**Back up `/opt/musiq-host/nodes`**: a lost key means re-activating that node.

Sizing: each node is a 32-byte key and one signed HTTPS request per run. A run takes
roughly 0.1–0.3 s per node, so with `MUSIQ_PARALLEL=16` about 10,000 nodes check in
within a few minutes on a small server (1 vCPU, 512 MB RAM). Nothing syncs a blockchain.

A license whose node is already running elsewhere (another host, or the member's own
machine) can't be activated by license id (`409 running_elsewhere`); the member moves
it by activating with their license key.

**One node per machine or container** (e.g. one container per license) works with the
single-node installer:

```bash
sudo MUSIQ_LICENSE_ID=<licenseId> MUSIQ_HOST_API_KEY=mnh_... \
  bash <(curl -fsSL https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main/install.sh)
```

The full host API (licenses and owners, members, node counts) is documented in the
MusIQ Network Node Host API guide shared with hosting partners.

## How rewards work (short version)

- Each reward day, every license with a valid heartbeat is **eligible**.
- Eligible licenses share the day's Node DAO Participation pool. While the network has
  fewer than 10,500 nodes, each node earns at most the litepaper rate
  (≈ 15.66 LYRIQ per day in year 1) and the rest is never minted.
- The day's list of eligible licenses is stored **on-chain** as a bitmap, so anyone can
  verify payouts. Members claim from their dashboard, to their own wallet.

Rewards are participation rewards for running network infrastructure — not an
investment return. See the MusIQ Node Terms.

## Security

- `node.key` and `license.key` are readable by root only (`/opt/musiq-agent` or `/opt/musiq-host`, mode 600).
- The signing key never leaves the server; the network only stores its public half.
- Heartbeats are signed, so nobody can check in for your license without your key.
