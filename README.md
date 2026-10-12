# Meridian

> *Crossing the line from Bookworm to Trixie, one node at a time.*

**Meridian** is a single Bash script that upgrades Proxmox VE nodes from **8.x to 9.x** in place, following the [official Proxmox upgrade guide](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9) — with pre-flight checks, automatic repo rewriting, rollback if the new repositories don't validate, and a JSON result for every run.

It's **safe by default**: run it with no flags and it only *looks*. Nothing on the node changes until you pass `--upgrade` and type the node name to confirm.

```
  __  __           _     _ _
 |  \/  | ___ _ __(_) __| (_) __ _ _ __
 | |\/| |/ _ \ '__| |/ _` | |/ _` | '_ \
 | |  | |  __/ |  | | (_| | | (_| | | | |
 |_|  |_|\___|_|  |_|\__,_|_|\__,_|_| |_|
```

---

## Read this first before running the script.

- **Back up every guest and test the backup** before upgrading. Meridian cannot verify your backups.
- **Don't run it from the web GUI shell** (Node → Shell). That session dies mid-upgrade. Meridian detects this and refuses.
- Use the **physical/IPMI console**, or SSH inside **`tmux`** or **`screen`**.
- **Clusters: one node at a time.** Upgrade, reboot, verify, *then* move to the next.
- Hyper-converged Ceph must already be on **Ceph 19.2 Squid**.
- Read the script before running it as root. That's just good practice.

---

## Features of this tool!

| | |
|---|---|
| **Read-only pre-flight** | 15+ checks: version baseline, disk space, session type, quorum, Ceph version/health, running guests, conflicting packages, third-party & backports repos, keyring, and known PVE 9 gotchas |
| **Runs `pve8to9 --full`** | Before, during and after — failures block the upgrade, warnings are surfaced in the summary |
| **Brings 8.x to latest 8.4 first** | If the node is below `8.4.1`, it updates on Bookworm before switching |
| **Repo rewrite with rollback** | Converts Debian entries to Trixie, writes deb822 `.sources` for PVE 9 (and Ceph Squid), disables bookworm-only third-party repos — and **restores the old config automatically** if `apt update` fails |
| **Auto-detects your repo** | Enterprise if you have an active subscription *and* use the enterprise repo, otherwise no-subscription |
| **Resumable** | Detects a half-finished upgrade (Trixie base, PVE still 8) and picks up at the dist-upgrade stage |
| **Backs up config** | `/etc/apt`, `/etc/pve`, network, grub, sysctl, lvm, ssh, chrony, package list → `/root/meridian-backup-<timestamp>/` |
| **Hard timeouts** | On every external call that can hang — *except* the dist-upgrade itself (killing dpkg mid-run is how you brick a node) |
| **Structured output** | End-of-run summary plus a JSON result per node, ready for pipelines |
| **Lock file** | Prevents two runs on the same node at once |

---

## Requirements

- Proxmox VE 8.x on Debian 12 (Bookworm), run as **root**
- At least **5 GB** free on `/` (10 GB+ recommended)
- Network access to the Debian and Proxmox repositories

Everything else the script uses (`perl`, `dpkg`, `pvesh`, `pvecm`…) is already on every PVE node.

---

## Quick start

```bash
wget https://raw.githubusercontent.com/Mr-Whiskerss/Meridian/main/meridian.sh
chmod +x meridian.sh

# 1. Look before you leap (changes nothing)
./meridian.sh --check

# 2. Upgrade (inside tmux/screen or on the console)
tmux new -s meridian
./meridian.sh --upgrade

# 3. Reboot, then confirm everything landed
systemctl reboot
./meridian.sh --verify
```

---

## Usage

```
meridian.sh [mode] [options]
```

### Modes

| Flag | What it does |
|---|---|
| `--check` *(default)* | Read-only pre-flight checks. Changes nothing. |
| `--upgrade` | Performs the 8 → 9 upgrade on this node. |
| `--verify` | Post-reboot verification: version, kernel, repos, quorum, `pve8to9`. |

### Upgrade options

| Flag | What it does |
|---|---|
| `--repo enterprise\|no-subscription` | Force the PVE 9 repository type (default: auto-detect). |
| `--ceph-repo enterprise\|no-subscription` | Force the Ceph Squid repository type (default: same as `--repo`). |
| `--non-interactive` | Unattended apt run. **Keeps your existing config files** and lists any new maintainer versions (`*.dpkg-dist`) for you to review afterwards. |
| `--lvm-migrate` | Run Proxmox's LVM autoactivation migration script if `pve8to9` asks for it. |
| `--remove-systemd-boot` | Remove the `systemd-boot` meta-package if `pve8to9` recommends it — including clearing that blocker before the upgrade starts. |
| `--reboot` | Reboot automatically 15 seconds after a successful upgrade. |
| `-y`, `--yes` | Skip the type-the-node-name confirmation. |
| `--force` | Proceed despite blocking pre-flight failures. **Not advised.** |

### Output

| Flag | What it does |
|---|---|
| `--json FILE` | Where to write the JSON result (default: `/var/log/meridian/meridian-<host>-<timestamp>.json`). |
| `-h`, `--help` | Show help. |
| `-V`, `--version` | Show version. |

### Exit codes

| Code | Meaning |
|---|---|
| `0` | Success / ready / verified |
| `1` | Blocking issues found |
| `2` | Usage or environment error (not root, not PVE, bad flag) |
| `3` | Upgrade step failed |
| `4` | Aborted at the confirmation prompt |

---

## What happens during `--upgrade`

| Stage | Action |
|---|---|
| **0 · Pre-flight** | All checks run. Any `FAIL` stops here (unless `--force`). You type the node name to confirm. Config is backed up. |
| **1 · Latest 8.4** | Only if below `8.4.1`: `apt update && apt dist-upgrade` on Bookworm, then `pve8to9 --full` again. |
| **2 · Repositories** | Snapshots `/etc/apt`. Debian lines → `trixie`. Old Proxmox, backports and bookworm-only third-party entries are disabled. New deb822 files are written. `apt update` must succeed with **no bookworm sources** — otherwise the old config is **restored** and nothing is upgraded. |
| **3 · Pre-fixes** | Disables the journald audit socket (stops log spam), removes `linux-image-amd64` if present, applies `pve8to9` hints you opted into. |
| **4 · Dist-upgrade** | `apt dist-upgrade` to Debian 13 + PVE 9. No timeout — a spinning disk can take an hour. |
| **5 · Post** | Installs `grub-efi-amd64` on UEFI + LVM-root systems, re-runs `pve8to9`, flags new maintainer config files, confirms PVE 9 is installed. |

### Config file prompts (interactive mode)

| File | Usual answer |
|---|---|
| `/etc/issue` | Keep yours (cosmetic, regenerated on boot) |
| `/etc/lvm/lvm.conf` | Install the maintainer's version if you didn't customise it |
| `/etc/ssh/sshd_config` | Maintainer's version if unmodified |
| `/etc/default/grub` | Keep yours if unsure — check the diff for kernel cmdline options |
| `/etc/chrony/chrony.conf` | Maintainer's version if unmodified |

---

## Clusters & multiple nodes

### Pre-flight the whole fleet (read-only, safe)

```bash
for node in pve1 pve2 pve3; do
  echo "=== ${node} ==="
  ssh root@"${node}" 'bash -s -- --check' < meridian.sh
done
```

### Rolling upgrade

1. Migrate guests that must stay up off the node.
2. `./meridian.sh --upgrade`
3. Reboot, then `./meridian.sh --verify`
4. Check every node is healthy and the cluster is quorate.
5. Repeat on the next node.

> Migrating guests **from older to newer** PVE always works. Newer → older isn't supported, so don't rely on moving guests back to un-upgraded nodes.

Once every node is on PVE 9, HA groups migrate to HA rules automatically.

---

## JSON output

Every run writes a result file, e.g.:

```json
{
  "tool": "meridian",
  "version": "1.0.1",
  "host": "pve1",
  "timestamp": "2026-10-12T14:30:00+01:00",
  "mode": "check",
  "state": "ready",
  "result": "ready",
  "pve_before": "8.4.14",
  "pve_after": "",
  "repo": "no-subscription",
  "ceph_repo": "no-subscription",
  "summary": {"pass": 9, "warn": 2, "fail": 0, "info": 5},
  "checks": [
    {"status": "PASS", "name": "Latest 8.4 baseline", "detail": "pve-manager 8.4.14 ≥ 8.4.1"},
    {"status": "WARN", "name": "Running guests", "detail": "2 VM(s), 3 CT(s) — migrate anything that must stay up; the rest go down at reboot"}
  ],
  "log": "/var/log/meridian/meridian-pve1-20261012-143000.log",
  "backup_dir": ""
}
```

Logs and `pve8to9` output live in `/var/log/meridian/`. In interactive mode the full apt transcript is in `/var/log/apt/term.log`.

---

## Homelab gotchas worth knowing

- **NVIDIA GPU on the host** (e.g. passed into a Plex/Jellyfin LXC): PVE 9 ships kernel 6.14. Drivers installed via DKMS or the `.run` installer must support it — install `proxmox-headers` and rebuild after the upgrade. Meridian warns if an `nvidia` module is loaded.
- **PCI passthrough VMs:** some setups break on 6.14. If a VM won't start, boot the previous kernel and pin it with `proxmox-boot-tool kernel pin`.
- **`/etc/sysctl.conf` is ignored on PVE 9.** Move settings (IP forwarding etc.) into `/etc/sysctl.d/99-local.conf`. Meridian flags this.
- **NIC names can change** with the new kernel. Have console access. PVE 9 includes `pve-network-interface-pinning` to pin names to `nicX`.
- **`/tmp` is now tmpfs** and old files in `/tmp` / `/var/tmp` get cleaned automatically on Trixie.
- **Old containers** with systemd ≤ 230 (CentOS 7, Ubuntu 16.04) won't run — cgroup v1 is gone.
- **Veeam users:** VMs on QEMU machine version ≥ 10.0 break Veeam backups; pin to `9.2+pve1` or wait.
- **Ceph "insecure key types" `HEALTH_ERR`** may appear after the first MON node reboots — services keep running; finish all nodes, then follow Proxmox's key migration docs.

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `pve8to9` FAIL: *systemd-boot meta-package installed* | Common on nodes installed from the 8.1–8.4 ISOs. Re-run with `--upgrade --remove-systemd-boot` and Meridian removes it, re-checks, then continues. Only keep it if you set up systemd-boot yourself (`proxmox-boot-tool` setups don't need the meta-package). |
| `apt update` fails at stage 2 | Meridian already restored your old repos. Check the log, fix the offending repo, re-run. |
| Upgrade interrupted (SSH dropped, etc.) | Reattach to tmux, or re-run `./meridian.sh --upgrade` — it detects the partial state and resumes. If dpkg is broken: `apt -f install`. |
| `You are attempting to remove the meta-package 'proxmox-ve'!` | A repo is still on Bookworm or has no Trixie build. Fix/remove it and retry. |
| Thin pool `pve/data` needs repair after reboot | `lvconvert --repair pve/data` |
| Won't boot (grub `disk lvmid/... not found`) | See [Recover From Grub Failure](https://pve.proxmox.com/wiki/Recover_From_Grub_Failure). |
| Web UI looks broken | Hard-refresh: `Ctrl+Shift+R` (`⌘+Alt+R` on macOS). |

Your pre-upgrade config is in `/root/meridian-backup-<timestamp>/`.

---

## References

- [Proxmox VE — Upgrade from 8 to 9](https://pve.proxmox.com/wiki/Upgrade_from_8_to_9)
- [Proxmox VE — Package Repositories](https://pve.proxmox.com/wiki/Package_Repositories)
- [Proxmox VE 9.0 known issues](https://pve.proxmox.com/wiki/Roadmap#9.0-known-issues)
- [Debian 13 (Trixie) release notes](https://www.debian.org/releases/trixie/release-notes/)

---

## Disclaimer

Meridian automates the documented procedure, but every Proxmox install is different. You run it at your own risk — **test on a non-critical node first** and keep good backups. Not affiliated with Proxmox Server Solutions GmbH.

## License

MIT © [Mr-Whiskerss](https://github.com/Mr-Whiskerss)
