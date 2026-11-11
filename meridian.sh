#!/usr/bin/env bash
# =============================================================================
#  Meridian — Proxmox VE 8 → 9 in-place upgrade helper
#  "Crossing the line from Bookworm to Trixie, one node at a time."
#
#  Author  : Mr-Whiskerss  (https://github.com/Mr-Whiskerss)
#  License : MIT
#  Docs    : README.md
#
#  Safe by default: with no flags Meridian runs read-only pre-flight checks
#  and changes nothing on the node. The upgrade only happens with --upgrade.
#
#  Follows the official procedure:
#    https://pve.proxmox.com/wiki/Upgrade_from_8_to_9
# =============================================================================

set -u
set -o pipefail

readonly MERIDIAN_VERSION="1.1.0"
TS="$(date +%Y%m%d-%H%M%S)"; readonly TS
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"; readonly HOST_SHORT
readonly LOG_DIR="/var/log/meridian"
readonly LOG_FILE="${LOG_DIR}/meridian-${HOST_SHORT}-${TS}.log"
readonly BACKUP_DIR="/root/meridian-backup-${TS}"
readonly KEYRING="/usr/share/keyrings/proxmox-archive-keyring.gpg"
readonly LVM_MIGRATION="/usr/share/pve-manager/migrations/pve-lvm-disable-autoactivation"
readonly DISABLED_TAG="# meridian-disabled: "
readonly SRC_D="/etc/apt/sources.list.d"

# Hard timeouts (seconds) for every external call that could hang.
# The dist-upgrade itself is deliberately NOT time-limited (see apt_dist_upgrade).
readonly T_SHORT=30
readonly T_APT_UPDATE=600
readonly T_PVE8TO9=900

# ---- options ---------------------------------------------------------------
MODE="check"             # check | upgrade | verify
REPO_CHOICE="auto"       # auto | enterprise | no-subscription
CEPH_REPO_CHOICE="auto"  # auto | enterprise | no-subscription
NONINTERACTIVE=0
ASSUME_YES=0
DO_REBOOT=0
FORCE=0
LVM_MIGRATE=0
REMOVE_SDBOOT=0
FIX_ALL=0                # --fix: apply every known safe fix without asking
JSON_OUT=""

# ---- run state -------------------------------------------------------------
STATE="unknown"          # ready | needs-8.4 | resume | done | unsupported
RESULT="incomplete"
PVE_BEFORE=""
PVE_AFTER=""
HYPERCONVERGED=0
HAD_CEPH_REPO=0
UEFI_LVM_ROOT=0
LOG_READY=""
P8_FAIL=0
P8_WARN=0
P8_OUT=""
P8_IDX=-1
declare -a C_STATUS=() C_NAME=() C_DETAIL=()
# Known fixes: sdboot | grub-removable | microcode
declare -A FIX_OK=() FIX_ASKED=() FIX_DONE=()

if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; B=""; D=""; BOLD=""; N=""
fi

# =============================================================================
#  Output helpers
# =============================================================================
banner() {
  printf '%s' "$B"
  cat <<'EOF'
  __  __           _     _ _
 |  \/  | ___ _ __(_) __| (_) __ _ _ __
 | |\/| |/ _ \ '__| |/ _` | |/ _` | '_ \
 | |  | |  __/ |  | | (_| | | (_| | | | |
 |_|  |_|\___|_|  |_|\__,_|_|\__,_|_| |_|
EOF
  printf '%s   Proxmox VE 8 → 9 upgrade helper · v%s%s\n\n' "$D" "$MERIDIAN_VERSION" "$N"
}

usage() {
  cat <<EOF
Usage: meridian.sh [mode] [options]

Modes (default: --check):
  --check                 Read-only pre-flight checks. Changes nothing.
  --upgrade               Upgrade this node from Proxmox VE 8 to 9.
  --verify                Post-reboot verification (version, kernel, repos, cluster).

Upgrade options:
  --repo TYPE             enterprise | no-subscription   (default: auto-detect)
  --ceph-repo TYPE        enterprise | no-subscription   (default: same as --repo)
  --non-interactive       Unattended apt run. Keeps your current config files and
                          lists any new maintainer versions for you to review.
  --fix                   Apply the known safe fixes pve8to9 asks for, without asking:
                          systemd-boot meta-package, GRUB removable EFI path,
                          missing CPU microcode. (Interactive runs offer them anyway.)
  --remove-systemd-boot   Only the systemd-boot fix (subset of --fix).
  --lvm-migrate           Run Proxmox's LVM autoactivation migration if pve8to9 asks.
  --reboot                Reboot automatically once the upgrade succeeds.
  -y, --yes               Skip the type-the-node-name confirmation.
  --force                 Continue despite blocking pre-flight failures (not advised).

Output:
  --json FILE             JSON result path
                          (default: ${LOG_DIR}/meridian-<host>-<timestamp>.json)
  -h, --help              Show this help
  -V, --version           Show version

Exit codes: 0 ok · 1 blockers/issues found · 2 usage/environment · 3 upgrade failed · 4 aborted
EOF
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

log() {
  printf '%s\n' "$*"
  if [[ -n "$LOG_READY" ]]; then
    printf '[%s] %s\n' "$(date +%T)" "$*" | strip_ansi >>"$LOG_FILE"
  fi
  return 0
}

section() { log ""; log "${BOLD}== $* ==${N}"; }

record() {
  local st="$1" name="$2" detail="${3:-}" col
  case "$st" in
    PASS) col=$G ;; WARN) col=$Y ;; FAIL) col=$R ;; *) col=$B ;;
  esac
  C_STATUS+=("$st"); C_NAME+=("$name"); C_DETAIL+=("$detail")
  log "  ${col}[$(printf '%-4s' "$st")]${N} ${name}${detail:+ ${D}— ${detail}${N}}"
}

count() {
  local want="$1" n=0 s
  for s in "${C_STATUS[@]}"; do [[ "$s" == "$want" ]] && n=$((n + 1)); done
  echo "$n"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  printf '%s' "$s"
}

die() {
  log "${R}[ERROR]${N} $1"
  RESULT="error"
  write_json
  exit "${2:-2}"
}

# =============================================================================
#  System helpers
# =============================================================================
pkg_installed()       { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pve_manager_version() { dpkg-query -W -f='${Version}' pve-manager 2>/dev/null; }
os_codename()         { ( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-unknown}" ); }
ver_ge()              { [[ -n "$1" ]] && dpkg --compare-versions "$1" ge "$2"; }

# True if any ancestor process is the web GUI's terminal proxy.
in_gui_shell() {
  local pid=$$ comm
  while [[ -n "$pid" && "$pid" -gt 1 ]]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$comm" == termproxy* ]] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}

# Active APT entries, one line per .list entry / per .sources stanza summary.
active_repo_lines() {
  local f
  shopt -s nullglob
  grep -hEv '^[[:space:]]*(#|$)' /etc/apt/sources.list "${SRC_D}"/*.list 2>/dev/null \
    | grep -E '^[[:space:]]*deb'
  for f in "${SRC_D}"/*.sources; do
    grep -qiE '^[[:space:]]*Enabled:[[:space:]]*no' "$f" && continue
    grep -hE '^[[:space:]]*(URIs|Suites|Components):' "$f" | paste -sd ' ' - | sed "s|^|${f##*/}: |"
  done
  shopt -u nullglob
}

cluster_versions() {
  local json nodes n st v out=""
  json=$(timeout "$T_SHORT" pvesh get /nodes --output-format json 2>/dev/null) || return 1
  nodes=$(printf '%s' "$json" | perl -MJSON::PP -0777 -ne \
    'my $d = decode_json($_); print join("\n", map { "$_->{node} " . ($_->{status} // "unknown") } @$d)') || return 1
  while read -r n st; do
    [[ -z "$n" ]] && continue
    if [[ "$st" == "online" ]]; then
      v=$(timeout "$T_SHORT" pvesh get "/nodes/${n}/version" --output-format json 2>/dev/null \
          | perl -MJSON::PP -0777 -ne 'print decode_json($_)->{version} // "?"' 2>/dev/null)
    else
      v="offline"
    fi
    out+="${n}=${v:-?} "
  done <<<"$nodes"
  printf '%s' "${out% }"
}

# Every node must be on the latest 8.4 (or already 9) before any node moves to 9.
check_cluster_peers() {
  local pair n v
  local -a behind=()
  for pair in $1; do
    n=${pair%%=*}; v=${pair#*=}
    [[ "$n" == "$HOST_SHORT" || "$v" == "offline" || "$v" == "?" ]] && continue
    ver_ge "$v" "8.4.1" || behind+=("${n} (${v})")
  done
  if (( ${#behind[@]} )); then
    record WARN "Other cluster nodes" "${behind[*]} below 8.4 — Proxmox wants every node on the latest 8.4 before any node moves to 9; run apt update && apt dist-upgrade there first"
  fi
}

check_two_node() {
  local st nodes
  st=$(timeout "$T_SHORT" pvecm status 2>/dev/null) || return 0
  nodes=$(awk '/^Nodes:/ {print $2; exit}' <<<"$st")
  if [[ "$nodes" == "2" ]] && ! grep -qi 'qdevice' <<<"$st"; then
    record INFO "Two-node cluster" "while this node reboots the other loses quorum — once it is down, run 'pvecm expected 1' on the other node if you need to manage guests (a QDevice avoids this)"
  fi
}

run_pve8to9() {
  local label="$1"
  P8_OUT="${LOG_DIR}/pve8to9-${label}-${HOST_SHORT}-${TS}.txt"
  if ! command -v pve8to9 >/dev/null 2>&1; then P8_FAIL="missing"; return 1; fi
  log "  ${D}running pve8to9 --full → ${P8_OUT}${N}"
  timeout "$T_PVE8TO9" pve8to9 --full 2>&1 | strip_ansi >"$P8_OUT"
  if ! grep -q '^FAILURES:' "$P8_OUT"; then P8_FAIL="incomplete"; P8_WARN="?"; return 1; fi
  P8_FAIL=$(awk '/^FAILURES:/ {print $2; exit}' "$P8_OUT")
  P8_WARN=$(awk '/^WARNINGS:/ {print $2; exit}' "$P8_OUT")
  return 0
}

record_pve8to9() {
  local label="$1" lines
  run_pve8to9 "$label"
  case "$P8_FAIL" in
    missing)
      record INFO "pve8to9 checklist" "not available yet — it ships with the latest 8.4 packages" ;;
    incomplete)
      record FAIL "pve8to9 checklist" "did not finish within ${T_PVE8TO9}s — see ${P8_OUT}" ;;
    0)
      if [[ "${P8_WARN:-0}" -gt 0 ]]; then
        lines=$(grep '^WARN:' "$P8_OUT" | head -n 3 | sed 's/^WARN: *//' | paste -sd ';' -)
        record WARN "pve8to9 checklist" "${P8_WARN} warning(s): ${lines} — full output: ${P8_OUT}"
      else
        record PASS "pve8to9 checklist" "no failures or warnings"
      fi ;;
    *)
      lines=$(grep '^FAIL:' "$P8_OUT" | head -n 3 | sed 's/^FAIL: *//' | paste -sd ';' -)
      record FAIL "pve8to9 checklist" "${P8_FAIL} failure(s): ${lines} — full output: ${P8_OUT}" ;;
  esac
  P8_IDX=$(( ${#C_STATUS[@]} - 1 ))
}

# Does the latest pve8to9 output raise a WARN/FAIL mentioning $1?
pve8to9_mentions() {
  [[ -f "$P8_OUT" ]] && grep -E -A1 '^(WARN|FAIL):' "$P8_OUT" | grep -qi "$1"
}

# =============================================================================
#  Known fixes — findings Meridian can resolve itself (with consent)
# =============================================================================
can_prompt() { (( ! NONINTERACTIVE && ! ASSUME_YES )) && [[ -r /dev/tty ]]; }

fix_desc() {
  case "$1" in
    sdboot)         echo "systemd-boot meta-package — remove it (pve8to9 FAIL; systemd-boot-efi/-tools stay for proxmox-boot-tool)" ;;
    grub-removable) echo "GRUB removable EFI path — let GRUB keep EFI/BOOT/BOOTX64.efi updated too" ;;
    microcode)      echo "CPU microcode — install it (enables Debian's non-free-firmware component)" ;;
  esac
}

# Fixable findings in the latest pve8to9 output, one per line.
fixable_items() {
  [[ -f "$P8_OUT" ]] || return 0
  pve8to9_mentions 'systemd-boot meta-package' && echo sdboot
  pve8to9_mentions 'Removable bootloader'      && echo grub-removable
  pve8to9_mentions 'microcode'                 && echo microcode
  return 0
}

# True if pve8to9 failed and every FAIL line is one Meridian has approval to fix.
p8_fails_all_fixable() {
  local other
  [[ -f "$P8_OUT" && "$P8_FAIL" =~ ^[0-9]+$ ]] && (( P8_FAIL > 0 )) || return 1
  [[ -n "${FIX_OK[sdboot]:-}" ]] || return 1
  other=$(grep '^FAIL:' "$P8_OUT" | grep -vci 'systemd-boot')
  (( other == 0 ))
}

# Decide which of the given fixes may be applied: --fix approves all,
# --remove-systemd-boot approves sdboot, otherwise ask once per item (interactive).
decide_fixes() {
  local it ans
  local -a new=()
  for it in "$@"; do
    [[ -n "${FIX_OK[$it]:-}" || -n "${FIX_ASKED[$it]:-}" ]] && continue
    if (( FIX_ALL )) || { [[ "$it" == sdboot ]] && (( REMOVE_SDBOOT )); }; then
      FIX_OK[$it]=1
    else
      new+=("$it")
    fi
  done
  (( ${#new[@]} )) || return 0
  for it in "${new[@]}"; do FIX_ASKED[$it]=1; done
  can_prompt || return 0
  log ""
  log "${B}${BOLD}Meridian can fix these pve8to9 findings for you:${N}"
  for it in "${new[@]}"; do log "  • $(fix_desc "$it")"; done
  read -r -p "Apply these fixes? [Y/n] " ans </dev/tty || ans="n"
  if [[ -z "$ans" || "$ans" =~ ^[Yy] ]]; then
    for it in "${new[@]}"; do FIX_OK[$it]=1; done
  fi
  return 0
}

fixes_hint() {
  local it
  local -a pending=()
  while read -r it; do
    [[ -n "$it" && -z "${FIX_OK[$it]:-}" && -z "${FIX_DONE[$it]:-}" ]] && pending+=("$it")
  done < <(fixable_items)
  (( ${#pending[@]} )) || return 0
  log "${Y}Fixable by Meridian:${N}"
  for it in "${pending[@]}"; do log "  • $(fix_desc "$it")"; done
  log "  Re-run with ${BOLD}--upgrade --fix${N}, or answer yes when --upgrade offers them."
}

fix_sdboot() {
  local removes
  # Simulate first: only ever remove the meta-package itself.
  removes=$(apt-get -s remove systemd-boot 2>/dev/null | awk '/^Remv /{print $2}' | paste -sd ' ' -)
  if [[ -z "$removes" ]]; then
    record PASS "systemd-boot meta-package" "not installed"; return 0
  fi
  if [[ "$removes" != "systemd-boot" ]]; then
    record FAIL "systemd-boot meta-package" "apt would also remove: ${removes} — left alone, check manually"; return 1
  fi
  if apt-get remove -y systemd-boot 2>&1 | tee -a "$LOG_FILE"; then
    record PASS "systemd-boot meta-package" "removed (systemd-boot-efi/-tools kept for proxmox-boot-tool)"
  else
    record FAIL "systemd-boot meta-package" "removal failed — run: apt remove systemd-boot"; return 1
  fi
}

fix_grub_removable() {
  if ! pkg_installed grub-efi-amd64; then
    record WARN "GRUB removable EFI path" "grub-efi-amd64 isn't installed (not GRUB on UEFI) — skipped, see ${P8_OUT}"; return 1
  fi
  echo 'grub-efi-amd64 grub2/force_efi_extra_removable boolean true' | debconf-set-selections -u
  if apt-get install --reinstall -y grub-efi-amd64 2>&1 | tee -a "$LOG_FILE"; then
    record PASS "GRUB removable EFI path" "GRUB now also keeps EFI/BOOT/BOOTX64.efi up to date"
  else
    record WARN "GRUB removable EFI path" "reinstalling grub-efi-amd64 failed — see ${LOG_FILE}"; return 1
  fi
}

fix_microcode() {
  local vendor pkg f tmp
  vendor=$(awk -F': ' '/^vendor_id/ {print $2; exit}' /proc/cpuinfo 2>/dev/null)
  case "$vendor" in
    GenuineIntel) pkg="intel-microcode" ;;
    AuthenticAMD) pkg="amd64-microcode" ;;
    *) record WARN "CPU microcode" "unknown CPU vendor '${vendor:-?}' — skipped"; return 1 ;;
  esac
  if pkg_installed "$pkg"; then record PASS "CPU microcode" "${pkg} already installed"; return 0; fi

  # Enable non-free-firmware on the Debian entries (one-line and deb822 formats).
  if [[ -f /etc/apt/sources.list ]]; then
    tmp=$(mktemp)
    awk '/^[[:space:]]*deb(-src)?[[:space:]]/ && /debian\.org/ && !/non-free-firmware/ { $0 = $0 " non-free-firmware" } { print }' \
      /etc/apt/sources.list >"$tmp" && cat "$tmp" >/etc/apt/sources.list
    rm -f "$tmp"
  fi
  shopt -s nullglob
  for f in "${SRC_D}"/*.sources; do
    grep -q 'debian\.org' "$f" || continue
    sed -i -E '/^[[:space:]]*Components:/{/non-free-firmware/! s/[[:space:]]*$/ non-free-firmware/}' "$f"
  done
  shopt -u nullglob

  apt_update || { record WARN "CPU microcode" "apt update failed after enabling non-free-firmware — install ${pkg} manually"; return 1; }
  if apt-get install -y "$pkg" 2>&1 | tee -a "$LOG_FILE"; then
    record PASS "CPU microcode" "${pkg} installed — active after the reboot"
  else
    record WARN "CPU microcode" "installing ${pkg} failed — see ${LOG_FILE}"; return 1
  fi
}

# Offer/apply known fixes for the latest pve8to9 run, then re-check if anything changed.
maybe_apply_fixes() {
  local label="$1" it applied=0 old_idx
  local -a items=() todo=()
  mapfile -t items < <(fixable_items)
  (( ${#items[@]} )) || return 0
  decide_fixes "${items[@]}"
  for it in "${items[@]}"; do
    [[ -n "${FIX_OK[$it]:-}" && -z "${FIX_DONE[$it]:-}" ]] && todo+=("$it")
  done
  if (( ${#todo[@]} )); then
    section "Applying known fixes (${label})"
    old_idx="$P8_IDX"
    for it in "${todo[@]}"; do
      case "$it" in
        sdboot)         fix_sdboot ;;
        grub-removable) fix_grub_removable ;;
        microcode)      fix_microcode ;;
      esac && { FIX_DONE[$it]=1; applied=1; }
    done
    if (( applied )); then
      if (( old_idx >= 0 )); then
        C_STATUS[old_idx]="INFO"
        C_DETAIL[old_idx]="superseded by the re-check after fixes (was: ${C_DETAIL[old_idx]})"
      fi
      record_pve8to9 "${label}-fixed"
    fi
  fi
  fixes_hint
  return 0
}

# Newest installed Proxmox kernel (e.g. 7.0.14-28-pve).
latest_pve_kernel() {
  find /lib/modules -mindepth 1 -maxdepth 1 -type d -name '*-pve' -printf '%f\n' 2>/dev/null | sort -V | tail -n1
}

# pve-manager version recorded by the most recent Meridian backup (for --verify).
last_backup_version() {
  local f
  f=$(find /root -maxdepth 2 -path '/root/meridian-backup-*/pveversion-before.txt' 2>/dev/null | sort | tail -n1)
  [[ -n "$f" ]] && awk '/^pve-manager:/ {print $2; exit}' "$f"
}

detect_repo_choice() {
  local sub_active=0 ent_active=0
  timeout "$T_SHORT" pvesubscription get 2>/dev/null | grep -qiE '^status:[[:space:]]*active' && sub_active=1
  active_repo_lines | grep -q 'enterprise\.proxmox\.com/debian/pve' && ent_active=1
  active_repo_lines | grep -q 'proxmox\.com/debian/ceph' && HAD_CEPH_REPO=1

  if [[ "$REPO_CHOICE" == "auto" ]]; then
    if (( sub_active && ent_active )); then REPO_CHOICE="enterprise"; else REPO_CHOICE="no-subscription"; fi
  fi
  [[ "$CEPH_REPO_CHOICE" == "auto" ]] && CEPH_REPO_CHOICE="$REPO_CHOICE"

  if [[ "$REPO_CHOICE" == "enterprise" ]] && (( ! sub_active )); then
    record WARN "Repository choice" "enterprise selected but no active subscription found — apt will return 401"
  else
    record INFO "Repository choice" "PVE 9: ${REPO_CHOICE}$( (( HYPERCONVERGED || HAD_CEPH_REPO )) && echo ", Ceph Squid: ${CEPH_REPO_CHOICE}")"
  fi
}

# =============================================================================
#  Pre-flight (read-only)
# =============================================================================
preflight() {
  section "Pre-flight checks on ${HOST_SHORT}"
  local pmv codename avail_kb avail_gb running_vm running_ct rootsrc active third backports pt cv cver ch session

  pmv=$(pve_manager_version); codename=$(os_codename); PVE_BEFORE="$pmv"
  record INFO "Installed" "pve-manager ${pmv:-?}, Debian ${codename}, kernel $(uname -r)"

  if ver_ge "$pmv" "9~"; then
    STATE="done"
    record PASS "Proxmox VE major version" "already on PVE 9 — nothing to upgrade"
    return 0
  elif [[ "$codename" == "trixie" ]]; then
    STATE="resume"
    record WARN "Partial upgrade detected" "Debian is trixie but pve-manager is ${pmv} — --upgrade resumes at the dist-upgrade stage"
  elif [[ "$codename" != "bookworm" ]]; then
    STATE="unsupported"
    record FAIL "Debian base" "expected bookworm, found ${codename}"
  elif ver_ge "$pmv" "8.4.1"; then
    STATE="ready"
    record PASS "Latest 8.4 baseline" "pve-manager ${pmv} ≥ 8.4.1"
  else
    STATE="needs-8.4"
    record WARN "Latest 8.4 baseline" "pve-manager ${pmv} < 8.4.1 — --upgrade brings the node to the latest 8.4 first"
  fi

  # Disk space
  avail_kb=$(df -Pk / | awk 'NR==2 {print $4}'); avail_gb=$(( avail_kb / 1024 / 1024 ))
  if (( avail_kb < 5 * 1024 * 1024 )); then
    record FAIL "Free space on /" "${avail_gb} GB — at least 5 GB required"
  elif (( avail_kb < 10 * 1024 * 1024 )); then
    record WARN "Free space on /" "${avail_gb} GB — 10 GB or more recommended"
  else
    record PASS "Free space on /" "${avail_gb} GB"
  fi

  # Session
  if in_gui_shell; then
    record FAIL "Session" "running inside the web GUI shell, which is cut off mid-upgrade — use SSH or the IPMI/physical console"
  elif [[ -n "${SSH_CONNECTION:-}" && -z "${TMUX:-}" && -z "${STY:-}" ]]; then
    record WARN "Session" "SSH without tmux/screen — a dropped connection could interrupt the upgrade"
  else
    session="console"; [[ -n "${SSH_CONNECTION:-}" ]] && session="ssh"
    [[ -n "${TMUX:-}" ]] && session+=" + tmux"; [[ -n "${STY:-}" ]] && session+=" + screen"
    record PASS "Session" "$session"
  fi

  # Cluster
  if [[ -f /etc/pve/corosync.conf ]]; then
    if timeout "$T_SHORT" pvecm status 2>/dev/null | grep -qE 'Quorate:[[:space:]]+Yes'; then
      record PASS "Cluster quorum" "quorate"
    else
      record FAIL "Cluster quorum" "not quorate — fix cluster health before upgrading"
    fi
    if cv=$(cluster_versions) && [[ -n "$cv" ]]; then
      record INFO "Cluster node versions" "$cv"
      check_cluster_peers "$cv"
    fi
    check_two_node
  else
    record INFO "Cluster" "standalone node"
  fi

  # Ceph (hyper-converged)
  if pkg_installed ceph-mon || pkg_installed ceph-osd || [[ -e /etc/pve/ceph.conf ]]; then
    HYPERCONVERGED=1
    cver=$(timeout "$T_SHORT" ceph --version 2>/dev/null | awk '{print $3}')
    if [[ "$cver" == 19.2* ]]; then
      record PASS "Ceph version" "Squid ${cver}"
    else
      record FAIL "Ceph version" "found ${cver:-unknown} — upgrade the cluster to Ceph 19.2 Squid before PVE 9"
    fi
    ch=$(timeout "$T_SHORT" ceph health 2>/dev/null | awk '{print $1}')
    if [[ "$ch" == "HEALTH_OK" ]]; then record PASS "Ceph health" "$ch"; else record WARN "Ceph health" "${ch:-unknown}"; fi
  fi

  # Guests
  running_vm=$(timeout "$T_SHORT" qm list 2>/dev/null | awk 'NR>1 && $3=="running"' | wc -l)
  running_ct=$(timeout "$T_SHORT" pct list 2>/dev/null | awk 'NR>1 && $2=="running"' | wc -l)
  if (( running_vm + running_ct > 0 )); then
    record WARN "Running guests" "${running_vm} VM(s), ${running_ct} CT(s) — migrate anything that must stay up; the rest go down at reboot"
  else
    record PASS "Running guests" "none"
  fi

  # Packages that conflict
  if pkg_installed linux-image-amd64; then
    record WARN "Debian kernel meta-package" "linux-image-amd64 conflicts with PVE 9 — --upgrade removes it first"
  fi

  # Repositories
  active=$(active_repo_lines)
  third=$(printf '%s\n' "$active" | grep -vE 'debian\.org|proxmox\.com' | grep -v '^[[:space:]]*$' || true)
  backports=$(printf '%s\n' "$active" | grep 'backports' || true)
  if [[ -n "$third" ]]; then
    record WARN "Third-party repositories" "$(printf '%s' "$third" | paste -sd ';' -) — confirm trixie builds exist; bookworm-only entries are disabled by --upgrade"
  fi
  if [[ -n "$backports" ]]; then
    record WARN "Backports" "backports entries found — the upgrade is untested with backports; --upgrade comments them out"
  fi
  detect_repo_choice

  # Known PVE 9 gotchas
  if [[ -f /etc/sysctl.conf ]] && grep -qEv '^[[:space:]]*([#;]|$)' /etc/sysctl.conf; then
    record WARN "/etc/sysctl.conf" "has active settings — PVE 9 no longer reads it; move them to /etc/sysctl.d/99-local.conf"
  fi
  if grep -qE 'post-up[[:space:]]+/usr/bin/systemctl[[:space:]]+restart[[:space:]]+frr' /etc/network/interfaces 2>/dev/null; then
    record FAIL "FRR full-mesh post-up" "deadlocks boot on PVE 9 — change it to: post-up /usr/bin/systemctl is-active --quiet frr.service && /usr/bin/systemctl restart frr.service || true"
  fi
  pt=$(grep -l '^hostpci' /etc/pve/qemu-server/*.conf 2>/dev/null | xargs -r -n1 basename | sed 's/\.conf$//' | paste -sd ',' -)
  if [[ -n "$pt" ]]; then
    record WARN "PCI passthrough VMs" "VMID ${pt} — some passthrough setups break on the new PVE 9 kernel; be ready to pin the old one"
  fi
  if lsmod 2>/dev/null | grep -q '^nvidia'; then
    record WARN "NVIDIA host driver" "must support the PVE 9 kernel (6.14 at 9.0, 7.0 by 9.2; vGPU: GRID 18.3+) — Meridian checks the DKMS build before you reboot"
  fi
  if [[ -f "$KEYRING" ]]; then
    record PASS "Proxmox archive keyring" "$KEYRING"
  else
    record WARN "Proxmox archive keyring" "${KEYRING} missing — --upgrade installs proxmox-archive-keyring before switching repos"
  fi
  rootsrc=$(findmnt -no SOURCE / 2>/dev/null)
  if [[ -d /sys/firmware/efi && "$rootsrc" == /dev/mapper/* ]]; then
    UEFI_LVM_ROOT=1
    record INFO "Boot" "UEFI with root on LVM — --upgrade installs grub-efi-amd64 to avoid the 'disk lvmid not found' bug"
  fi

  record INFO "Backups" "Meridian cannot verify backups — make sure every guest on this node has a tested one"
  record_pve8to9 "pre"
}

# =============================================================================
#  Upgrade stages (only reached with --upgrade)
# =============================================================================
confirm() {
  (( ASSUME_YES )) && return 0
  local ans=""
  log ""
  log "${Y}${BOLD}This will upgrade ${HOST_SHORT} from Proxmox VE 8 to 9.${N}"
  log "${Y}Guests on this node go down at the final reboot. Have a tested backup.${N}"
  read -r -p "Type the node name (${HOST_SHORT}) to continue: " ans </dev/tty || ans=""
  if [[ "$ans" != "$HOST_SHORT" ]]; then
    log "Confirmation did not match — aborting. Nothing was changed."
    RESULT="aborted"; print_summary; write_json; exit 4
  fi
}

backup_config() {
  section "Backing up configuration"
  mkdir -p "$BACKUP_DIR" && chmod 700 "$BACKUP_DIR"
  tar -czf "${BACKUP_DIR}/etc-apt.tgz" -C / etc/apt 2>/dev/null
  tar -czf "${BACKUP_DIR}/etc-pve.tgz" -C / etc/pve 2>/dev/null
  local f
  for f in /etc/network/interfaces /etc/default/grub /etc/sysctl.conf /etc/lvm/lvm.conf \
           /etc/ssh/sshd_config /etc/chrony/chrony.conf /etc/hosts /etc/resolv.conf; do
    [[ -f "$f" ]] && cp -a "$f" "${BACKUP_DIR}/$(echo "${f#/}" | tr '/' '_')"
  done
  pveversion -v >"${BACKUP_DIR}/pveversion-before.txt" 2>&1
  dpkg -l >"${BACKUP_DIR}/packages-before.txt" 2>&1
  record PASS "Configuration backup" "$BACKUP_DIR"
}

apt_update() {
  local tmp rc
  tmp=$(mktemp)
  log "  ${D}apt-get update…${N}"
  timeout "$T_APT_UPDATE" apt-get update 2>&1 | tee "$tmp"
  rc=${PIPESTATUS[0]}
  strip_ansi <"$tmp" >>"$LOG_FILE"
  if (( rc != 0 )) || grep -qE '^(E:|Err:)' "$tmp"; then
    rm -f "$tmp"; record FAIL "apt-get update" "errors reported (exit ${rc}) — see ${LOG_FILE}"; return 1
  fi
  rm -f "$tmp"; return 0
}

apt_dist_upgrade() {
  # Deliberately NO timeout: killing dpkg mid-upgrade can leave the node
  # unbootable, and a slow root disk can legitimately take an hour or more.
  local rc
  if (( NONINTERACTIVE )); then
    DEBIAN_FRONTEND=noninteractive APT_LISTCHANGES_FRONTEND=none \
      apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade 2>&1 \
      | tee -a "$LOG_FILE"
    rc=${PIPESTATUS[0]}
  else
    log "  ${D}interactive apt run — full transcript is kept in /var/log/apt/term.log${N}"
    APT_LISTCHANGES_FRONTEND=none apt-get dist-upgrade
    rc=$?
  fi
  return "$rc"
}

stage_latest_84() {
  section "Stage 1 — bring the node to the latest Proxmox VE 8.4"
  apt_update || return 3
  if ! apt_dist_upgrade; then record FAIL "8.4 update" "apt-get dist-upgrade failed"; return 3; fi
  local pmv; pmv=$(pve_manager_version)
  if ! ver_ge "$pmv" "8.4.1"; then
    record FAIL "Latest 8.4 baseline" "still at ${pmv} — check this node's PVE 8 repositories"; return 3
  fi
  record PASS "Latest 8.4 baseline" "now at ${pmv}"
  record_pve8to9 "after-8.4"
  maybe_apply_fixes "after-8.4"
  if [[ "$P8_FAIL" != "0" ]] && (( ! FORCE )); then
    log "${R}pve8to9 still reports blockers — fix them and re-run Meridian.${N}"
    RESULT="blocked"; return 1
  fi
  return 0
}

write_deb822() {
  cat >"$1" <<EOF
Types: deb
URIs: $2
Suites: trixie
Components: $3
Signed-By: ${KEYRING}
EOF
}

restore_repos() {
  log "${Y}Restoring the previous APT configuration…${N}"
  rm -f "${SRC_D}/proxmox.sources" "${SRC_D}/pve-enterprise.sources" "${SRC_D}/ceph.sources"
  tar -xzf "${BACKUP_DIR}/etc-apt-pre-trixie.tgz" -C /
  timeout "$T_APT_UPDATE" apt-get update >/dev/null 2>&1
  record FAIL "APT repositories" "trixie repositories failed validation — previous config restored, nothing was upgraded"
}

stage_repos() {
  section "Stage 2 — switch APT repositories to Debian Trixie / PVE 9"
  local f tmp file uri comp

  if [[ ! -f "$KEYRING" ]]; then
    log "  installing proxmox-archive-keyring (still on bookworm repos)…"
    if ! { timeout "$T_APT_UPDATE" apt-get update >/dev/null 2>&1 && apt-get install -y proxmox-archive-keyring; } \
       || [[ ! -f "$KEYRING" ]]; then
      record FAIL "Proxmox archive keyring" "could not install ${KEYRING}"; return 3
    fi
  fi

  tar -czf "${BACKUP_DIR}/etc-apt-pre-trixie.tgz" -C / etc/apt
  mkdir -p "${BACKUP_DIR}/disabled-sources"

  if [[ -f /etc/apt/sources.list ]]; then
    tmp=$(mktemp)
    awk -v tag="$DISABLED_TAG" '
      /^[[:space:]]*#/ || /^[[:space:]]*$/ { print; next }
      /proxmox\.com/                       { print tag $0; next }
      /backports/                          { print tag $0; next }
      /debian\.org/                        { gsub(/bookworm/, "trixie"); print; next }
      /bookworm/                           { print tag $0; next }
                                           { print }
    ' /etc/apt/sources.list >"$tmp" && cat "$tmp" >/etc/apt/sources.list
    rm -f "$tmp"
    record PASS "sources.list" "Debian entries → trixie; Proxmox, backports and bookworm-only lines commented out"
  fi

  shopt -s nullglob
  for f in "${SRC_D}"/*.list "${SRC_D}"/*.sources; do
    if grep -q 'proxmox\.com' "$f"; then
      mv "$f" "${BACKUP_DIR}/disabled-sources/"
      log "  retired ${f##*/} (old Proxmox repo — replaced below)"
    elif grep -q 'debian\.org' "$f"; then
      sed -i 's/bookworm/trixie/g' "$f"
      log "  ${f##*/}: bookworm → trixie"
    elif grep -q 'bookworm' "$f"; then
      mv "$f" "${BACKUP_DIR}/disabled-sources/"
      record WARN "Third-party repo disabled" "${f##*/} pointed at bookworm — add a trixie version after the upgrade (copy in ${BACKUP_DIR}/disabled-sources)"
    fi
  done
  shopt -u nullglob

  if [[ "$REPO_CHOICE" == "enterprise" ]]; then
    file="${SRC_D}/pve-enterprise.sources"; uri="https://enterprise.proxmox.com/debian/pve"; comp="pve-enterprise"
  else
    file="${SRC_D}/proxmox.sources"; uri="http://download.proxmox.com/debian/pve"; comp="pve-no-subscription"
  fi
  write_deb822 "$file" "$uri" "$comp"
  record PASS "Proxmox VE 9 repository" "${REPO_CHOICE} → ${file}"

  if (( HYPERCONVERGED || HAD_CEPH_REPO )); then
    if [[ "$CEPH_REPO_CHOICE" == "enterprise" ]]; then
      uri="https://enterprise.proxmox.com/debian/ceph-squid"; comp="enterprise"
    else
      uri="http://download.proxmox.com/debian/ceph-squid"; comp="no-subscription"
    fi
    write_deb822 "${SRC_D}/ceph.sources" "$uri" "$comp"
    record PASS "Ceph Squid repository" "${CEPH_REPO_CHOICE} → ${SRC_D}/ceph.sources"
  fi

  if ! apt_update; then restore_repos; return 3; fi
  if apt-cache policy 2>/dev/null | grep -q 'n=bookworm'; then
    log "${R}apt still sees bookworm sources after the switch.${N}"
    restore_repos; return 3
  fi
  record PASS "APT repositories" "only trixie sources active"
  return 0
}

handle_pve8to9_hints() {
  if pve8to9_mentions 'autoactivation'; then
    if (( LVM_MIGRATE )) && [[ -x "$LVM_MIGRATION" ]]; then
      if "$LVM_MIGRATION" 2>&1 | tee -a "$LOG_FILE"; then
        record PASS "LVM autoactivation" "guest volumes migrated"
      else
        record WARN "LVM autoactivation" "migration script failed — run ${LVM_MIGRATION} manually"
      fi
    else
      record WARN "LVM autoactivation" "run ${LVM_MIGRATION} (strongly recommended for shared LVM) or re-run with --lvm-migrate"
    fi
  fi
}

stage_prefixes() {
  section "Stage 3 — pre-upgrade fixes"
  if systemctl disable --now systemd-journald-audit.socket >/dev/null 2>&1; then
    record PASS "Kernel audit socket" "disabled to stop audit log spam during the upgrade"
  fi
  if pkg_installed linux-image-amd64; then
    if apt-get remove -y linux-image-amd64 2>&1 | tee -a "$LOG_FILE"; then
      record PASS "linux-image-amd64" "removed (conflicts with PVE 9)"
    else
      record FAIL "linux-image-amd64" "removal failed"; return 3
    fi
  fi
  handle_pve8to9_hints
  return 0
}

stage_dist_upgrade() {
  section "Stage 4 — dist-upgrade to Debian Trixie + Proxmox VE 9"
  log "  This can take from a few minutes (SSD) to an hour or more (spinning disk)."
  if (( ! NONINTERACTIVE )); then
    log "  Config prompts — usual answers: /etc/issue keep · lvm.conf new · sshd_config new if unmodified"
    log "                                  /etc/default/grub keep if unsure · chrony.conf new if unmodified"
  fi
  if ! apt_dist_upgrade; then
    record FAIL "dist-upgrade" "apt failed — DO NOT REBOOT. Inspect the log, fix repos, then try: apt -f install && apt dist-upgrade"
    return 3
  fi
  record PASS "dist-upgrade" "completed"
  return 0
}

stage_post() {
  section "Stage 5 — post-upgrade checks"
  local leftovers
  PVE_AFTER=$(pve_manager_version)

  if (( UEFI_LVM_ROOT )); then
    if apt-get install -y grub-efi-amd64 2>&1 | tee -a "$LOG_FILE"; then
      record PASS "grub-efi-amd64" "installed (UEFI + LVM root boot fix)"
    else
      record WARN "grub-efi-amd64" "install failed — run: apt install grub-efi-amd64 BEFORE rebooting"
    fi
  fi

  record_pve8to9 "post"
  maybe_apply_fixes "post"
  handle_pve8to9_hints
  check_nvidia_dkms

  leftovers=$(find /etc -xdev \( -name '*.dpkg-dist' -o -name '*.ucf-dist' \) -newer "${BACKUP_DIR}/etc-apt.tgz" 2>/dev/null | paste -sd ',' -)
  if [[ -n "$leftovers" ]]; then
    record WARN "New maintainer config files" "${leftovers} — diff against yours (lvm.conf and chrony.conf usually want the new one)"
  fi

  if ver_ge "$PVE_AFTER" "9~"; then
    record PASS "Proxmox VE version" "pve-manager ${PVE_AFTER} — reboot pending"
    RESULT="upgraded-reboot-pending"
    return 0
  fi
  record FAIL "Proxmox VE version" "pve-manager is ${PVE_AFTER:-?} after the upgrade — investigate before rebooting"
  return 3
}

# An NVIDIA driver that isn't built for the new kernel means no GPU after the reboot.
check_nvidia_dkms() {
  local latest
  lsmod 2>/dev/null | grep -q '^nvidia' || [[ -d /var/lib/dkms/nvidia ]] || return 0
  latest=$(latest_pve_kernel)
  if command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -i '^nvidia' | grep -F "$latest" | grep -q 'installed'; then
    record PASS "NVIDIA DKMS module" "built for ${latest}"
  elif command -v dkms >/dev/null 2>&1 && dkms status 2>/dev/null | grep -qi '^nvidia'; then
    record WARN "NVIDIA DKMS module" "NOT built for ${latest} — before rebooting: apt install proxmox-headers-${latest} && dkms autoinstall -k ${latest}; if it won't build, use a driver that supports this kernel or pin the old one (proxmox-boot-tool kernel pin $(uname -r))"
  else
    record WARN "NVIDIA host driver" "loaded but not managed by DKMS — reinstall it for ${latest} after the reboot (GPU passthrough won't work until then)"
  fi
}

do_upgrade() {
  local rc
  if [[ "$STATE" == "done" ]]; then
    log "Already on Proxmox VE 9 — running verification instead."
    verify; RESULT="already-upgraded"; return 0
  fi
  local blockers
  local -a items=()
  blockers=$(count FAIL)
  mapfile -t items < <(fixable_items)
  (( ${#items[@]} )) && decide_fixes "${items[@]}"
  if p8_fails_all_fixable; then
    blockers=$(( blockers - 1 ))   # the pve8to9 FAIL is one Meridian will fix itself
  fi
  if (( blockers > 0 )) && (( ! FORCE )); then
    log ""
    log "${R}${blockers} blocking issue(s) found — fix them and re-run (or --force if you are certain).${N}"
    fixes_hint
    RESULT="blocked"; return 1
  fi
  confirm
  backup_config

  if (( ${#items[@]} )); then
    maybe_apply_fixes "pre"
    if [[ "$P8_FAIL" =~ ^[0-9]+$ ]] && (( P8_FAIL > 0 )) && (( ! FORCE )); then
      log "${R}pve8to9 still reports blockers after the fixes — see ${P8_OUT}${N}"
      RESULT="blocked"; return 1
    fi
  fi

  if [[ "$STATE" == "needs-8.4" ]]; then stage_latest_84 || return $?; fi
  if [[ "$STATE" == "resume" ]]; then
    section "Resuming partial upgrade"
    apt_update || { RESULT="error"; return 3; }
  else
    stage_repos || { RESULT="error"; return 3; }
  fi
  stage_prefixes     || { RESULT="error"; return 3; }
  stage_dist_upgrade || { RESULT="error"; return 3; }
  stage_post; rc=$?
  (( rc != 0 )) && RESULT="error"
  return "$rc"
}

# =============================================================================
#  Verify (read-only, after reboot)
# =============================================================================
verify() {
  section "Verification on ${HOST_SHORT}"
  local pmv codename kver latest cv remaining pair v
  pmv=$(pve_manager_version); codename=$(os_codename); kver=$(uname -r); PVE_AFTER="$pmv"
  [[ -n "$PVE_BEFORE" && "$PVE_BEFORE" != "$pmv" ]] || PVE_BEFORE=$(last_backup_version)

  if ver_ge "$pmv" "9~" && [[ "$codename" == "trixie" ]]; then
    STATE="done"
    record PASS "Proxmox VE version" "pve-manager ${pmv} on Debian ${codename}"
  else
    STATE="incomplete"
    record FAIL "Proxmox VE version" "pve-manager ${pmv:-?} on Debian ${codename}"
  fi

  latest=$(latest_pve_kernel)
  if [[ "$kver" != *-pve ]] || ! ver_ge "${kver%%-*}" "6.14"; then
    record WARN "Running kernel" "${kver} — reboot into the PVE 9 kernel"
  elif [[ -n "$latest" && "$latest" != "$kver" ]]; then
    record WARN "Running kernel" "${kver}, but ${latest} is installed — reboot pending (or a kernel is pinned)"
  else
    record PASS "Running kernel" "$kver"
  fi

  if lsmod 2>/dev/null | grep -q '^nvidia'; then
    record PASS "NVIDIA driver" "loaded on ${kver}"
  elif [[ -d /var/lib/dkms/nvidia ]]; then
    record WARN "NVIDIA driver" "DKMS package present but the module isn't loaded — check: dkms status; nvidia-smi"
  fi

  if apt-cache policy 2>/dev/null | grep -q 'n=bookworm'; then
    record FAIL "APT repositories" "bookworm sources still active"
  else
    record PASS "APT repositories" "no bookworm sources"
  fi

  if [[ -f /etc/sysctl.conf ]] && grep -qEv '^[[:space:]]*([#;]|$)' /etc/sysctl.conf; then
    record WARN "/etc/sysctl.conf" "still has settings that PVE 9 ignores — move them to /etc/sysctl.d/"
  fi

  if [[ -f /etc/pve/corosync.conf ]]; then
    if timeout "$T_SHORT" pvecm status 2>/dev/null | grep -qE 'Quorate:[[:space:]]+Yes'; then
      record PASS "Cluster quorum" "quorate"
    else
      record FAIL "Cluster quorum" "not quorate"
    fi
    if cv=$(cluster_versions) && [[ -n "$cv" ]]; then
      record INFO "Cluster node versions" "$cv"
      remaining=$(for pair in $cv; do v=${pair#*=}; [[ "$v" == "offline" ]] || ver_ge "$v" "9~" || printf '%s ' "$pair"; done)
      if [[ -n "$remaining" ]]; then
        record INFO "Next node" "still on PVE 8: ${remaining% } — upgrade one at a time, as with this one"
      fi
    fi
    check_two_node
  fi

  record_pve8to9 "verify"
  log "  ${D}Tip: force-reload the web UI (Ctrl+Shift+R) to clear the cached PVE 8 interface.${N}"
}

# =============================================================================
#  Summary & JSON
# =============================================================================
print_summary() {
  local i
  section "Summary — ${HOST_SHORT}"
  log "  Mode    : ${MODE}"
  log "  State   : ${STATE}"
  log "  Result  : ${BOLD}${RESULT}${N}"
  local ver
  if [[ -n "$PVE_BEFORE" && -n "$PVE_AFTER" && "$PVE_BEFORE" != "$PVE_AFTER" ]]; then
    ver="${PVE_BEFORE} → ${PVE_AFTER}"
  else
    ver="${PVE_AFTER:-${PVE_BEFORE:-?}}"
  fi
  log "  Version : ${ver}"
  (( ${#FIX_DONE[@]} )) && log "  Fixed   : ${!FIX_DONE[*]}"
  log "  Checks  : ${G}$(count PASS) pass${N} · ${Y}$(count WARN) warn${N} · ${R}$(count FAIL) fail${N} · ${B}$(count INFO) info${N}"
  if (( $(count WARN) + $(count FAIL) > 0 )); then
    log "  Needs attention:"
    for i in "${!C_STATUS[@]}"; do
      if [[ "${C_STATUS[$i]}" == "WARN" || "${C_STATUS[$i]}" == "FAIL" ]]; then
        log "    - [${C_STATUS[$i]}] ${C_NAME[$i]}"
      fi
    done
  fi
  log "  Log     : ${LOG_FILE}"
  [[ -d "$BACKUP_DIR" ]] && log "  Backup  : ${BACKUP_DIR}"
  log "  JSON    : ${JSON_OUT}"
}

write_json() {
  [[ -n "$LOG_READY" && -n "$JSON_OUT" ]] || return 0
  local i k first=1 bdir=""
  [[ -d "$BACKUP_DIR" ]] && bdir="$BACKUP_DIR"
  {
    printf '{\n'
    printf '  "tool": "meridian",\n  "version": "%s",\n' "$MERIDIAN_VERSION"
    printf '  "host": "%s",\n  "timestamp": "%s",\n' "$(json_escape "$HOST_SHORT")" "$(date -Is)"
    printf '  "mode": "%s",\n  "state": "%s",\n  "result": "%s",\n' "$MODE" "$STATE" "$RESULT"
    printf '  "pve_before": "%s",\n  "pve_after": "%s",\n' "$(json_escape "$PVE_BEFORE")" "$(json_escape "$PVE_AFTER")"
    printf '  "repo": "%s",\n  "ceph_repo": "%s",\n' "$REPO_CHOICE" "$CEPH_REPO_CHOICE"
    printf '  "fixes_applied": [%s],\n' "$(for k in "${!FIX_DONE[@]}"; do printf '"%s",' "$k"; done | sed 's/,$//')"
    printf '  "summary": {"pass": %d, "warn": %d, "fail": %d, "info": %d},\n' \
      "$(count PASS)" "$(count WARN)" "$(count FAIL)" "$(count INFO)"
    printf '  "checks": [\n'
    for i in "${!C_STATUS[@]}"; do
      (( first )) || printf ',\n'
      first=0
      printf '    {"status": "%s", "name": "%s", "detail": "%s"}' \
        "${C_STATUS[$i]}" "$(json_escape "${C_NAME[$i]}")" "$(json_escape "${C_DETAIL[$i]}")"
    done
    printf '\n  ],\n'
    printf '  "log": "%s",\n  "backup_dir": "%s"\n}\n' "$LOG_FILE" "$bdir"
  } >"$JSON_OUT"
}

# =============================================================================
#  Main
# =============================================================================
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check)               MODE="check" ;;
      --upgrade)             MODE="upgrade" ;;
      --verify)              MODE="verify" ;;
      --repo)                REPO_CHOICE="${2:-}"; shift ;;
      --ceph-repo)           CEPH_REPO_CHOICE="${2:-}"; shift ;;
      --non-interactive)     NONINTERACTIVE=1 ;;
      --lvm-migrate)         LVM_MIGRATE=1 ;;
      --remove-systemd-boot) REMOVE_SDBOOT=1 ;;
      --fix|--fix-known)     FIX_ALL=1 ;;
      --reboot)              DO_REBOOT=1 ;;
      -y|--yes)              ASSUME_YES=1 ;;
      --force)               FORCE=1 ;;
      --json)                JSON_OUT="${2:-}"; shift ;;
      -h|--help)             usage; exit 0 ;;
      -V|--version)          echo "meridian ${MERIDIAN_VERSION}"; exit 0 ;;
      *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
  done
  case "$REPO_CHOICE" in auto|enterprise|no-subscription) ;;
    *) echo "--repo must be 'enterprise' or 'no-subscription'" >&2; exit 2 ;; esac
  case "$CEPH_REPO_CHOICE" in auto|enterprise|no-subscription) ;;
    *) echo "--ceph-repo must be 'enterprise' or 'no-subscription'" >&2; exit 2 ;; esac
  if [[ "$MODE" != "upgrade" ]] && (( NONINTERACTIVE || LVM_MIGRATE || REMOVE_SDBOOT || FIX_ALL || DO_REBOOT || FORCE )); then
    echo "Note: upgrade options are ignored outside --upgrade." >&2
  fi
}

main() {
  local rc=0
  parse_args "$@"
  banner

  [[ $EUID -eq 0 ]] || { echo "Meridian must run as root." >&2; exit 2; }
  command -v pveversion >/dev/null 2>&1 || { echo "This doesn't look like a Proxmox VE node (pveversion not found)." >&2; exit 2; }

  mkdir -p "$LOG_DIR" && chmod 700 "$LOG_DIR"
  LOG_READY=1
  [[ -n "$JSON_OUT" ]] || JSON_OUT="${LOG_DIR}/meridian-${HOST_SHORT}-${TS}.json"

  exec 9>/run/meridian.lock
  flock -n 9 || die "another Meridian run is already in progress on this node" 2

  log "${D}Meridian v${MERIDIAN_VERSION} · host ${HOST_SHORT} · mode ${MODE} · log ${LOG_FILE}${N}"

  case "$MODE" in
    check)
      preflight
      if [[ "$STATE" == "done" ]]; then
        verify; RESULT="already-upgraded"
        (( $(count FAIL) > 0 )) && rc=1
      elif (( $(count FAIL) > 0 )); then
        RESULT="blocked"; rc=1
        fixes_hint
      else
        RESULT="ready"
        fixes_hint
      fi
      ;;
    verify)
      verify
      if (( $(count FAIL) > 0 )); then RESULT="issues-found"; rc=1; else RESULT="verified"; fi
      ;;
    upgrade)
      preflight
      do_upgrade; rc=$?
      ;;
  esac

  print_summary
  write_json

  if [[ "$RESULT" == "upgraded-reboot-pending" ]]; then
    log ""
    if (( DO_REBOOT )); then
      log "${G}Upgrade complete. Rebooting in 15 seconds — Ctrl+C to cancel.${N}"
      log "After the reboot run: $0 --verify"
      sleep 15
      systemctl reboot
    else
      log "${G}Upgrade complete.${N} Reboot when ready (systemctl reboot), then run: $0 --verify"
      log "Clusters: finish and verify this node before starting the next one."
    fi
  fi
  exit "$rc"
}

main "$@"
