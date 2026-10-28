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

Install non-interactively by setting environment variables:

| Variable | Purpose |
|---|---|
| `MUSIQ_LICENSE_KEY` | The member's license key (skips the prompt) |
| `MUSIQ_HOST_API_KEY` | Your host API key — tags the node as hosted by you |
| `MUSIQ_API_BASE` | API base URL (default `https://musiqnetwork.com`) |
| `MUSIQ_SCHEDULE` | systemd `OnCalendar` for heartbeats (default every 6 h) |

```bash
sudo MUSIQ_LICENSE_KEY=MSQ-XXXX-XXXX-XXXX MUSIQ_HOST_API_KEY=mnh_... \
  bash <(curl -fsSL https://raw.githubusercontent.com/musiq-network/musiq-node-setup/main/install.sh)
```

### Node API (summary)

| Method & path | Auth | Purpose |
|---|---|---|
| `POST /api/nodes/v1/activate` | license key (+ optional host key) | `{licenseKey, nodePublicKey, agentVersion}` → `{licenseId, tokenId, memberId}` |
| `POST /api/nodes/v1/heartbeat` | Ed25519 signature | Body `{licenseId, ts, agentVersion}`; header `X-Signature` = base64 signature of the exact body bytes |
| `GET /api/nodes/v1/licenses` | `Authorization: Bearer <host key>` | All licenses: owner, on-chain token, node key, last heartbeat (paginated with `cursor`) |
| `GET /api/nodes/v1/licenses/{licenseId}` | host key | One license plus its last 30 days of heartbeats |
| `GET /api/nodes/v1/days/{day}` | public | A reward day's heartbeat count and on-chain settlement |

Heartbeats count for the day containing `ts` and are accepted until two days after
that day ends, so a delayed delivery still counts.

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

- `node.key` and `license.key` are readable by root only (`/opt/musiq-agent`, mode 600).
- The signing key never leaves the server; the network only stores its public half.
- Heartbeats are signed, so nobody can check in for your license without your key.
