# Fluxer Self-Hosting Installer

Single-shot, fully non-interactive installer for a [Fluxer](https://github.com/fluxerapp/fluxer) deployment on a fresh Ubuntu 24.04 VPS. Drop the script onto a clean root shell, point it at a domain whose A-record already resolves to the host, and ~10 minutes later you have a working instance with TLS, voice, file storage and admin access.

[Русский README](README.ru.md)

## TL;DR

```bash
curl -fsSL https://raw.githubusercontent.com/<your-fork>/fluxer-installer/main/install.sh \
  -o install.sh
bash install.sh --domain chat.example.com --email admin@example.com
```

When it finishes, open `https://chat.example.com` and register. The first account becomes admin.

## Requirements

| Component | Minimum |
| --- | --- |
| OS | Ubuntu 24.04 LTS (Noble), x86_64 |
| Privileges | `root` (the script runs `apt`, edits `/etc/sysctl.d/`, manages systemd units) |
| CPU / RAM / Disk | 4 vCPU, 8 GiB RAM, 80 GiB NVMe (SeaweedFS gets cranky below) |
| Network | Public IPv4, 22 / 80 / 443 / 7881-tcp / 7882-udp reachable |
| DNS | A-record for `--domain` pointing at this host, propagated (no CDN proxy in front, otherwise ACME HTTP-01 may fail) |

## Usage

```text
bash install.sh [options]

Required:
  --domain DOMAIN         Public FQDN with A-record pointing to this server.
  --email EMAIL           Contact email for VAPID (web-push) registration.

Optional:
  --branch BRANCH         fluxerapp/fluxer branch for deploy templates (default: main).
  --server-ip IP          Override auto-detected public IP used as LiveKit node_ip.
  --skip-upgrade          Skip the apt full upgrade pass.
  --skip-firewall         Skip ufw configuration (delegate to provider firewall).
  --clean                 docker-compose down + rm -rf /opt/fluxer before installing.
  -h, --help
```

The script is **idempotent**. Re-running it on a host that is already provisioned does not regenerate secrets, does not overwrite `livekit.yaml` data, and only `docker compose pull` / `up -d` will perform meaningful work if the upstream images changed.

## What gets installed

| Stage | Component | Notes |
| --- | --- | --- |
| 1 | apt full upgrade (skippable) | `DEBIAN_FRONTEND=noninteractive`, `Dpkg::--force-confold` so existing configs are preserved. |
| 2 | base packages | `ca-certificates curl gnupg ufw fail2ban unattended-upgrades jq` |
| 3 | `fail2ban` | Enabled + started via systemd. |
| 4 | UFW | Default deny-incoming / allow-outgoing; rules `22/tcp 80/tcp 443/tcp 7881/tcp 7882/udp`; `ufw --force enable`. |
| 5 | Docker CE + Compose v2 | Official `download.docker.com/linux/ubuntu` repo, GPG-pinned, `docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin`. |
| 6 | Fluxer deploy templates | `docker-compose.yml`, `Caddyfile`, `livekit.yaml`, `.env.example` fetched from `fluxerapp/fluxer@<branch>/deploy/self-hosting/`. |
| 7 | `.env` (public part) | `FLUXER_DOMAIN`, `*_SCHEME=https`, `*_PORT=443`, `*_CADDY_SITE_ADDRESS`, `*_VAPID_EMAIL`, email subsystem disabled. |
| 8 | `.env` (secrets) | Ten 256-bit hex secrets via `openssl rand -hex 32`, one 256-bit base64 secret (`UPLOAD_RELAY`), one VAPID key pair generated in an ephemeral `node:24-alpine` container. Only replaces values still set to `CHANGE_ME`. |
| 9 | `livekit.yaml` | Replaced with a known-good config: `use_external_ip: false`, `node_ip` set to the detected/specified public IP, RTC ports `7881-tcp` / `7882-udp`. |
| 10 | `/etc/sysctl.d/99-livekit.conf` | `net.core.rmem_max = net.core.wmem_max = 5_000_000` for LiveKit UDP throughput; `sysctl --system` applies immediately. |
| 11 | Voice env + override | `FLUXER_LIVEKIT_URL=wss://$DOMAIN/livekit` and a `FLUXER_LIVEKIT_DEFAULT_REGION` JSON appended to `.env`; `docker-compose.override.yml` exposes both to `api` and `worker` services. |
| 12 | `docker compose pull && up -d` | 17 images, ~7 GiB total. |
| 13 | SeaweedFS buckets | `fluxer`, `fluxer-uploads`, `fluxer-downloads`, `fluxer-reports`, `fluxer-harvests` created via `weed shell` over `docker compose exec -T` (the upstream `seaweedfs-init` container is known to race with the master and silently no-op). |
| 14 | Verification | `docker compose ps`, last few Caddy certificate log lines, five HTTPS `/_health` probes against `--domain`. |

## How the non-interactivity is enforced

A normal `apt upgrade` on a fresh Ubuntu 24.04 VPS will eventually pop a TUI in three places:

1. **`debconf`** (most common — `openssh-server`, `grub-pc`, etc. ask "keep local version / install maintainer's"). Suppressed by `DEBIAN_FRONTEND=noninteractive` + `Dpkg::Options::=--force-confold` so the local copy always wins. This is what keeps the SSH session alive across the upgrade.
2. **`needrestart`** (post-install service-restart picker). Suppressed by `NEEDRESTART_MODE=a` and an in-place edit of `/etc/needrestart/needrestart.conf` setting `$nrconf{restart} = 'a'`. Services are restarted automatically; the kernel-restart prompt is skipped.
3. **`ufw enable`** (confirmation prompt). Suppressed by `ufw --force enable`.

There are no other interactive points in the pipeline.

## Configuration

Everything tunable lives in `/opt/fluxer/.env`. After the installer finishes you can edit the file and `cd /opt/fluxer && docker compose up -d` to apply.

The most common follow-ups:

- **SMTP**: set `FLUXER_EMAIL_ENABLED=true`, `FLUXER_EMAIL_PROVIDER=smtp`, then the provider-specific `SMTP_*` block.
- **Branding**: log in to `https://$DOMAIN/admin` after first registration; the Instance Setup wizard offers logo/name fields.
- **Retention**: same admin panel, "Retention" section.

The `livekit.yaml` is overwritten on every install run — if you customize it, either store the patched file in version control next to the script or remove the corresponding `cat > livekit.yaml <<EOF` block.

## Verification

The installer prints:

```
==> container status:
NAME                       STATUS              PORTS
fluxer-api-1               Up                  ...
fluxer-caddy-1             Up                  0.0.0.0:80, 0.0.0.0:443
fluxer-livekit-1           Up                  0.0.0.0:7881, 0.0.0.0:7882/udp
...

==> caddy TLS status:
  ... certificate obtained successfully ...

==> health checks against https://chat.example.com :
  /_health             200
  /api/_health         200
  /gateway/_health     200
  /media/_health       200
  /admin/_health       200
```

All five 200s mean every Fluxer subsystem responds end-to-end through Caddy. If a probe returns `000` or `FAIL`, see the troubleshooting section below.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `apt install` hangs for minutes with `Waiting for cache lock` | A concurrent `unattended-upgrades` cycle is holding `/var/lib/dpkg/lock-frontend`. | Wait it out, or `systemctl stop unattended-upgrades.service && fuser -k /var/lib/dpkg/lock-frontend`, then re-run. |
| `dpkg was interrupted, you must manually run 'dpkg --configure -a'` | A previous apt run was killed mid-way. | `DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confold` then re-run the installer. |
| Health checks return `000` or TLS alert | DNS A-record points to a CDN/anti-DDoS proxy instead of the host; Let's Encrypt cannot reach port 80 directly. | Bypass the proxy or set a dedicated A-record on a subdomain pointing straight at the VPS. |
| `livekit` container in `Restarting` loop | `node_ip` is wrong or `use_external_ip: true` is back. | Inspect `/opt/fluxer/livekit.yaml`, ensure `use_external_ip: false` and `node_ip: <public IPv4>`. |
| Voice channel spins forever in the client | `FLUXER_LIVEKIT_URL` / `FLUXER_LIVEKIT_DEFAULT_REGION` not in `.env`, or the override file did not propagate to `api` / `worker`. | `grep FLUXER_LIVEKIT /opt/fluxer/.env`, then `docker compose up -d --force-recreate api worker`. |
| `fs.ls /buckets` empty after install | The race between `seaweedfs-init` and the SeaweedFS master happened. | The installer creates the five buckets defensively; re-run or run the create loop manually (see installer step 13). |
| `error: beginning MaxStartups throttling` in `journalctl -u ssh` | sshd is dropping concurrent unauthenticated connection attempts. | Reduce parallel SSH probes; in `sshd_config` raise `MaxStartups 30:60:200` if you actually need many parallel logons. |

## Security notes

- All secrets in `.env` are generated locally with `openssl rand`; nothing is uploaded anywhere.
- `.env` is `chmod 600` immediately after fetch.
- The installer does **not** harden SSH (password auth, root login, port). That belongs in a follow-up — recommended next steps: install your public key into `~/.ssh/authorized_keys`, set `PasswordAuthentication no` and `PermitRootLogin prohibit-password` in `/etc/ssh/sshd_config.d/10-hardening.conf`, then `systemctl reload ssh`.
- UFW does not protect Docker-published ports by default — `iptables` rules added by Docker bypass UFW chains. If you need a defense-in-depth, also configure the firewall in the provider panel (aeza, Hetzner, etc.) with the same allow list.

## License

The installer itself is plain bash; treat it as MIT. Fluxer upstream is licensed under its own terms — see [fluxerapp/fluxer](https://github.com/fluxerapp/fluxer).
