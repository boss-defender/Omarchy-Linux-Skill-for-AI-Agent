#!/usr/bin/env bash
# ==============================================================================
#  zram_swap_conf.sh  -  permanent zram + swap file configurator
#
#  Run it from ANY shell (fish, bash, zsh, Oh My Zsh ...):
#       chmod +x zram_swap_conf.sh
#       ./zram_swap_conf.sh
#
#  What it does
#    1. detects your distro, shell, RAM, target filesystem and free space
#    2. recommends zram + swap sizes for THIS machine, asks what you want
#       (zram can't exceed usable RAM, the swap file leaves a 1 GB reserve)
#       and lets you review
#    3. asks for your sudo password and then
#         - backs up everything it is going to touch
#         - disables the current zram / swap-file setup
#         - configures zram + creates the swap file
#         - saves it permanently (zram-generator / systemd + /etc/fstab)
#         - verifies the result
#    4. if anything fails it restores your previous configuration
#  With hibernation resume settings, only zram is changed; existing swap stays
#  untouched. On Omarchy with Btrfs, this script uses /zramconf-swap/swapfile
#  to avoid its reserved /swap/swapfile hibernation path.
#
#  Options
#    -y, --yes        skip questions; missing sizes use the recommendations
#        --zram SIZE  zram size, e.g. 14, 8G, 512M       (default unit: GB)
#        --swap SIZE  swap file size, e.g. 4, 2G, 0=none (default unit: GB)
#                     (with --yes and no size given, the recommended size is used)
#    -n, --dry-run    show the whole flow but change nothing
#        --no-anim    disable animations / colors
#        --no-tune    do not apply this script's kernel tuning
#        --tune       explicitly apply this script's kernel tuning
#    -h, --help       this help
#    -V, --version
#
#  Supported: Fedora (and RHEL family), Arch / Manjaro / EndeavourOS / Omarchy /
#  CachyOS, Debian / Ubuntu / Linux Mint / Pop!_OS / Zorin / Kali and any other
#  systemd distro (generic mode).  Filesystems for the swap file: btrfs, ext2/3/4, xfs.
# ==============================================================================

case "${BASH_VERSION:-}" in
  ''|[0-3].*|4.[0-3].*)
    echo "This script needs bash 4.4 or newer. Run it as ./zram_swap_conf.sh" >&2
    exit 1 ;;
esac

set -u
set -o pipefail
shopt -s extglob
export LC_NUMERIC=C
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/sbin:/usr/sbin:/sbin"

# ------------------------------------------------------------------------------
#  Constants and global state
# ------------------------------------------------------------------------------
readonly SCRIPT_VERSION="2.1.0"
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG_FILE="${TMPDIR:-/tmp}/zram_swap_conf-${TS}.log"
BACKUP_DIR="/var/backups/zram_swap_conf/${TS}"
GEN_DROPIN="/etc/systemd/zram-generator.conf.d/zzzz-zram-swap-conf.conf"
SVC_NAME="zram-swap-conf.service"
SVC_FILE="/etc/systemd/system/${SVC_NAME}"
SVC_BIN="/usr/local/sbin/zram-swap-conf-setup"
SVC_CONF="/etc/zram-swap-conf.conf"
ZRAM_PRIO=100
SWAP_PRIO=10
ZRAM_MIN_MIB=256
SWAP_MIN_MIB=128
DISK_RESERVE_MIB=1024   # always leave at least 1 GB free on the disk
SYSCTL_FILE="/etc/sysctl.d/99-zram-swap-conf.conf"
CONFLICT_UNITS=(zramswap.service zram-config.service zram-swap.service zramd.service zram.service systemd-swap.service)

DRY_RUN=0; ASSUME_YES=0; NO_ANIM=0; TUNE=1; TUNE_SPECIFIED=0
ARG_ZRAM=""; ARG_SWAP=""

# detection results
OS_ID="unknown"; OS_LIKE=""; OS_NAME="Linux"; FAMILY="generic"; IS_OMARCHY=0
USER_NAME=""; USER_HOME=""; LOGIN_SHELL=""; SHELL_NAME=""; SHELL_EXTRA=""; TERM_NAME=""
KERNEL=""; RAM_MIB=0; RAM_CAP_MIB=0; ROOT_FS=""; SWAP_FS=""; DESKTOP=""
DISK_DEV=""; DISK_KIND="unknown"; DISK_MODEL=""; DISK_SIZE_MIB=0
FS_SIZE_MIB=0; FS_FREE_MIB=0; SWAP_MAX_MIB=0; SWAP_POSSIBLE=0
REC_ZRAM_MIB=0; REC_SWAP_MIB=0; REC_WHY=""

# plan
ZRAM_MIB=0; SWAP_MIB=0; SWAP_DO=0; SWAP_DISABLE_OLD=0; SWAP_LEAVE_EXISTING=0; OMARCHY_LEGACY_SWAP=0; SWAP_SKIP=""; SWAPFILE=""; ZRAM_ALGO=""
BACKEND="generator"; GEN_INSTALLED=0; GEN_OLD=0
REPLACE_FILES=(); ACTIVE_OLD=(); WARNINGS=(); NOTES=(); PLAN_ERR=""
BTRFS_SUBVOL_CHECK_REQUIRED=0; HIBERNATION_CONFIGURED=0; OMARCHY_HIBERNATION_CONFIGURED=0
OMARCHY_TUNE_CLEANUP=0

# runtime state
BACKUP_READY=0; RUN_DONE=0; ROLLED_BACK=0
FSTAB_TOUCHED=0; CONF_TOUCHED=0; TUNE_TOUCHED=0
STEP_PID=""; KEEPALIVE_PID=""; PROG_FILE=""; PROG_TOTAL=0
REPLY_LINE=""; ASK_RESULT=0; PARSED_MIB=0
LIVE_OK=1

# ------------------------------------------------------------------------------
#  Arguments
# ------------------------------------------------------------------------------
usage() {
  sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//; s/^#$//'
}

parse_args() {
  while (( $# )); do
    case "$1" in
      -h|--help)    usage; exit 0 ;;
      -V|--version) echo "zram_swap_conf.sh $SCRIPT_VERSION"; exit 0 ;;
      -y|--yes)     ASSUME_YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      --no-anim)    NO_ANIM=1 ;;
      --no-tune)    TUNE=0; TUNE_SPECIFIED=1 ;;
      --tune)       TUNE=1; TUNE_SPECIFIED=1 ;;
      --zram=*)     ARG_ZRAM=${1#*=} ;;
      --swap=*)     ARG_SWAP=${1#*=} ;;
      --zram|--swap)
        if (( $# < 2 )); then echo "Option $1 needs a value." >&2; exit 2; fi
        if [[ $1 == --zram ]]; then ARG_ZRAM=$2; else ARG_SWAP=$2; fi
        shift ;;
      *) echo "Unknown option: $1  (try --help)" >&2; exit 2 ;;
    esac
    shift
  done
}

# ------------------------------------------------------------------------------
#  UI: colors, glyphs, boxes, spinner
# ------------------------------------------------------------------------------
setup_ui() {
  local nc
  UI_COLOR=0; UI_ANIM=0; UTF=0
  if [[ -t 1 ]]; then
    UI_ANIM=1
    if [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]]; then UI_COLOR=1; fi
  fi
  (( NO_ANIM )) && { UI_ANIM=0; UI_COLOR=0; }
  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8*|*[Uu][Tt][Ff]8*) UTF=1 ;;
  esac

  R=""; B=""; D=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""
  if (( UI_COLOR )); then
    nc=$(tput colors 2>/dev/null || echo 8)
    [[ $nc =~ ^[0-9]+$ ]] || nc=8
    R=$'\e[0m'; B=$'\e[1m'; D=$'\e[2m'
    if (( nc >= 256 )); then
      RED=$'\e[38;5;203m'; GRN=$'\e[38;5;114m'; YEL=$'\e[38;5;221m'
      BLU=$'\e[38;5;75m';  MAG=$'\e[38;5;177m'; CYN=$'\e[38;5;80m'; GRY=$'\e[38;5;245m'
    else
      RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
      MAG=$'\e[35m'; CYN=$'\e[36m'; GRY=$'\e[90m'
    fi
  fi

  if (( UTF )); then
    G_OK="✔"; G_ERR="✘"; G_WARN="⚠"; G_INFO="ℹ"; G_PROMPT="❯"; G_PHASE="▌"; G_DOT="•"
    SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    BAR_FULL="█"; BAR_EMPTY="░"
    BOX_TL="╭"; BOX_TR="╮"; BOX_BL="╰"; BOX_BR="╯"; BOX_H="─"; BOX_V="│"
  else
    G_OK="+"; G_ERR="x"; G_WARN="!"; G_INFO="i"; G_PROMPT=">"; G_PHASE="#"; G_DOT="*"
    SPIN=('|' '/' '-' '\')
    BAR_FULL="#"; BAR_EMPTY="-"
    BOX_TL="+"; BOX_TR="+"; BOX_BL="+"; BOX_BR="+"; BOX_H="-"; BOX_V="|"
  fi
  BOX_W=64
  CLR=""
  (( UI_ANIM )) && CLR=$'\r\e[K'
}

nap() { (( UI_ANIM )) && sleep "$1"; return 0; }

repeat() {  # repeat STRING COUNT
  local s=$1 n=$2 out=""
  while (( n > 0 )); do out+=$s; n=$(( n - 1 )); done
  printf '%s' "$out"
}

trunc() {  # trunc STRING MAX
  local s=$1 max=$2
  if (( ${#s} > max )); then printf '%s...' "${s:0:max-3}"; else printf '%s' "$s"; fi
}

line_ok()   { printf '  %s%s%s %s\n' "$GRN" "$G_OK"   "$R" "$*"; }
line_warn() { printf '  %s%s%s %s\n' "$YEL" "$G_WARN" "$R" "$*"; }
line_err()  { printf '  %s%s%s %s\n' "$RED" "$G_ERR"  "$R" "$*"; }
line_info() { printf '  %s%s%s %s\n' "$BLU" "$G_INFO" "$R" "$*"; }
line_dim()  { printf '  %s%s%s\n' "$D" "$*" "$R"; }

die() { line_err "$*"; exit 1; }

phase() {
  printf '\n  %s%s%s %s%s%s\n' "$MAG" "$G_PHASE" "$R" "$B" "$1" "$R"
  printf '  %s%s%s\n' "$GRY" "$(repeat "$BOX_H" $(( BOX_W - 2 )))" "$R"
}

box_top() {
  local title=${1:-} n
  if [[ -n $title ]]; then
    n=$(( BOX_W - 5 - ${#title} )); (( n < 1 )) && n=1
    printf '  %s%s%s%s %s%s%s %s%s%s\n' "$GRY" "$BOX_TL" "$BOX_H" "$R" "$B" "$title" "$R" \
      "$GRY" "$(repeat "$BOX_H" "$n")$BOX_TR" "$R"
  else
    printf '  %s%s%s%s\n' "$GRY" "$BOX_TL" "$(repeat "$BOX_H" $(( BOX_W - 2 )))$BOX_TR" "$R"
  fi
}
box_line() {
  local s=${1:-} plain pad
  plain=${s//$'\e'\[+([0-9;])m/}
  pad=$(( BOX_W - 4 - ${#plain} )); (( pad < 0 )) && pad=0
  printf '  %s%s%s %s%*s %s%s%s\n' "$GRY" "$BOX_V" "$R" "$s" "$pad" "" "$GRY" "$BOX_V" "$R"
}
box_kv() { box_line "${D}$(printf '%-12s' "$1")${R} $(trunc "$2" $(( BOX_W - 18 )))"; }
box_bottom() {
  printf '  %s%s%s\n' "$GRY" "$BOX_BL$(repeat "$BOX_H" $(( BOX_W - 2 )))$BOX_BR" "$R"
}

banner() {
  local -a art=(
"███████╗██████╗  █████╗ ███╗   ███╗"
"╚══███╔╝██╔══██╗██╔══██╗████╗ ████║"
"  ███╔╝ ██████╔╝███████║██╔████╔██║"
" ███╔╝  ██╔══██╗██╔══██║██║╚██╔╝██║"
"███████╗██║  ██║██║  ██║██║ ╚═╝ ██║"
"╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝     ╚═╝"
"                  &"
"██████╗ ██╗    ██╗  █████╗  ██████╗"
"██╔═══╝ ██║    ██║ ██╔══██╗ ██╔══██╗"
"█████╗  ██║ █╗ ██║ ███████║ ██████╔╝"
"╚═══██╗ ██║███╗██║ ██╔══██║ ██╔═══╝"
"██████╔╝ ╚███╔███╔╝ ██║  ██║ ██║"
"╚═════╝   ╚══╝╚══╝  ╚═╝  ╚═╝ ╚═╝"
  )
  local -a grad=(51 45 39 33 99 135 177 135 99 33 39 45 51)
  local i col
  printf '\n'
  if (( UTF )); then
    for i in "${!art[@]}"; do
      col=""
      (( UI_COLOR )) && col=$'\e[38;5;'"${grad[i]}"m
      printf '   %s%s%s\n' "$col" "${art[i]}" "$R"
      nap 0.05
    done
  else
    printf '   %sZRAM & SWAP%s\n' "$B" "$R"
  fi
  printf '   %sZRAM + SWAP CONFIGURATOR%s  %sv%s%s\n' "$B" "$R" "$D" "$SCRIPT_VERSION" "$R"
  printf '   %spermanent  %s  safe  %s  reversible%s\n' "$D" "$G_DOT" "$G_DOT" "$R"
  if (( DRY_RUN )); then
    printf '\n   %s%s DRY RUN - nothing on your system will be changed%s\n' "$YEL" "$G_WARN" "$R"
  fi
  printf '\n'
}

# ---- spinner -----------------------------------------------------------------
make_bar() {  # make_bar PERCENT WIDTH  -> BAR
  local pct=$1 w=$2 f
  f=$(( pct * w / 100 ))
  BAR="$(repeat "$BAR_FULL" "$f")$(repeat "$BAR_EMPTY" $(( w - f )))"
}
progress_suffix() {
  [[ -n $PROG_FILE && $PROG_TOTAL -gt 0 ]] || return 0
  local cur pct
  cur=$(stat -c %s "$PROG_FILE" 2>/dev/null || echo 0)
  [[ $cur =~ ^[0-9]+$ ]] || cur=0
  pct=$(( cur * 100 / PROG_TOTAL )); (( pct > 100 )) && pct=100
  make_bar "$pct" 20
  printf '  %s%s%s %3d%%' "$CYN" "$BAR" "$R" "$pct"
}

# run_step [-s] "label" function [args...]
#   Runs the function in the background (output -> log file) behind a spinner.
#   -s : soft step, a failure is shown as a warning instead of an error.
run_step() {
  local soft=0 label rc el i=0 started=$SECONDS
  if [[ $1 == -s ]]; then soft=1; shift; fi
  label=$1; shift
  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  STEP_PID=$!
  if (( UI_ANIM )); then
    printf '\e[?25l'
    while kill -0 "$STEP_PID" 2>/dev/null; do
      printf '%s  %s%s%s %s%s' "$CLR" "$CYN" "${SPIN[i % ${#SPIN[@]}]}" "$R" "$label" "$(progress_suffix)"
      i=$(( i + 1 ))
      sleep 0.08
    done
  fi
  wait "$STEP_PID"; rc=$?
  STEP_PID=""
  el=$(( SECONDS - started ))
  (( UI_ANIM )) && printf '\e[?25h'
  if (( rc == 0 )); then
    printf '%s  %s%s%s %s' "$CLR" "$GRN" "$G_OK" "$R" "$label"
    (( el >= 2 )) && printf ' %s(%ss)%s' "$D" "$el" "$R"
    printf '\n'
  elif (( soft )); then
    printf '%s  %s%s%s %s %s(skipped - see log)%s\n' "$CLR" "$YEL" "$G_WARN" "$R" "$label" "$D" "$R"
  else
    printf '%s  %s%s%s %s\n' "$CLR" "$RED" "$G_ERR" "$R" "$label"
    if [[ -s $LOG_FILE ]]; then
      tail -n 6 "$LOG_FILE" 2>/dev/null | while IFS= read -r l; do printf '      %s%s%s\n' "$D" "$l" "$R"; done
    fi
  fi
  return "$rc"
}

# ------------------------------------------------------------------------------
#  Input helpers
# ------------------------------------------------------------------------------
have_tty_input() { [[ -t 0 ]] || { : </dev/tty; } 2>/dev/null; }

read_line() {  # -> REPLY_LINE ; returns 1 on EOF / no input
  local v
  if [[ -t 0 ]]; then
    IFS= read -r v || return 1
  elif { : </dev/tty; } 2>/dev/null; then
    IFS= read -r v </dev/tty || return 1
  else
    return 1
  fi
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  REPLY_LINE=$v
}

fmt_mib() {
  local m=$1
  if (( m == 0 )); then printf 'none'; return 0; fi
  if (( m >= 1024 )); then
    if (( m % 1024 == 0 )); then printf '%d GB' $(( m / 1024 ))
    else awk -v m="$m" 'BEGIN{x=sprintf("%.1f", m/1024); sub(/\.0$/, "", x); printf "%s GB", x}'; fi
  else
    printf '%d MB' "$m"
  fi
}

# parse "14", "14G", "14GB", "1.5g", "512M" ... -> PARSED_MIB (default unit GB)
parse_size() {
  local s=$1 num unit mult parsed re
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  s=${s,,}
  re='^([0-9]+([.][0-9]+)?)(g|gb|gib|m|mb|mib)?$'
  [[ $s =~ $re ]] || return 1
  num=${BASH_REMATCH[1]}; unit=${BASH_REMATCH[3]:-g}
  case $unit in g*) mult=1024 ;; *) mult=1 ;; esac
  # Convert in awk so leading-zero input stays decimal and huge values cannot
  # overflow Bash's signed arithmetic or awk's printf %d conversion.
  parsed=$(awk -v n="$num" -v m="$mult" 'BEGIN {
    value = (n + 0) * m
    if (value >= 9000000000000000) {
      print "9223372036854775807"
    } else {
      value = int(value + 0.5)
      if (value == 0 && n > 0) value = 1
      printf "%.0f\n", value
    }
  }') || return 1
  [[ $parsed =~ ^[0-9]+$ ]] || return 1
  PARSED_MIB=$parsed
  return 0
}

# ask_size TITLE HINT DEFAULT_MIB MIN_MIB MAX_MIB ALLOW_ZERO PRESET MAX_REASON
#   Re-asks until the answer is valid. With --yes and no preset the default is used.
ask_size() {
  local title=$1 hint=$2 def=$3 min=$4 max=$5 zero=$6 preset=${7:-} why=${8:-the maximum} ans val
  while true; do
    if [[ -n $preset ]]; then
      ans=$preset; preset=""
    elif (( ASSUME_YES )); then
      ans=""
    else
      printf '\n  %s%s%s\n  %s%s%s\n' "$B" "$title" "$R" "$D" "$hint" "$R"
      printf '  %s%s%s %s[Enter = %s]%s ' "$CYN" "$G_PROMPT" "$R" "$D" "$(fmt_mib "$def")" "$R"
      read_line || { printf '\n'; line_warn "No input available. Aborting."; exit 130; }
      ans=$REPLY_LINE
    fi
    if [[ -z $ans ]]; then
      val=$def
    elif parse_size "$ans"; then
      val=$PARSED_MIB
    else
      line_err "I couldn't understand '$ans'. Type a number like 8, 8G, 1.5G or 512M."
      (( ASSUME_YES )) && exit 1
      continue
    fi
    if (( val == 0 )); then
      if (( zero )); then ASK_RESULT=0; return 0; fi
      line_err "This value can't be 0."; (( ASSUME_YES )) && exit 1; continue
    fi
    if (( val > max )); then
      line_err "Not possible: $(fmt_mib "$val") is bigger than $why ($(fmt_mib "$max"))."
      line_dim "Please enter $(fmt_mib "$max") or less."
      (( ASSUME_YES )) && exit 1; continue
    fi
    if (( val < min )); then
      line_err "Too small - the minimum is $(fmt_mib "$min")."; (( ASSUME_YES )) && exit 1; continue
    fi
    ASK_RESULT=$val
    return 0
  done
}

# ------------------------------------------------------------------------------
#  Privilege helper
# ------------------------------------------------------------------------------
as_root() {
  if (( DRY_RUN )); then
    printf '[dry-run] %s\n' "$*" >>"$LOG_FILE"
    [[ -t 0 ]] || cat >/dev/null
    return 0
  fi
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

authenticate() {
  phase "Authentication"
  if (( DRY_RUN )); then line_ok "Dry run - sudo not needed"; return 0; fi
  if (( EUID == 0 )); then line_ok "Running as root"; return 0; fi
  command -v sudo >/dev/null 2>&1 || die "sudo is not installed. Re-run this script as root (su -c ./zram_swap_conf.sh)."
  line_info "Administrator rights are needed to change swap settings."
  if ! sudo -v; then
    die "Authentication failed or was cancelled. Nothing was changed."
  fi
  line_ok "Authenticated"
  (
    while true; do
      sudo -n true 2>/dev/null || exit 0
      sleep 45
      kill -0 "$$" 2>/dev/null || exit 0
    done
  ) >/dev/null 2>&1 </dev/null &
  KEEPALIVE_PID=$!
}

# ------------------------------------------------------------------------------
#  System probing
# ------------------------------------------------------------------------------
meminfo_kb() { awk -v k="$1:" '$1==k{print $2; exit}' /proc/meminfo; }
swap_table() { swapon --noheadings --raw --bytes --show=NAME,TYPE,SIZE,USED,PRIO 2>/dev/null; }
is_swap_active() { swap_table | awk -v d="$1" '$1==d{f=1} END{exit !f}'; }
in_array() { local n=$1 x; shift; for x in "$@"; do [[ $x == "$n" ]] && return 0; done; return 1; }
lexically_after() { local LC_ALL=C; [[ $1 > $2 ]]; }

omarchy_legacy_swap_present() {
  (( IS_OMARCHY )) || return 1
  # The old script used this exact path and mode 0600; a normal user may not
  # be able to inspect it with swaplabel, so any existing path is preserved.
  [[ -e /swap/swapfile || -L /swap/swapfile ]] && return 0
  if is_swap_active /swap/swapfile; then return 0; fi
  if awk '$1 !~ /^#/ && $1 == "/swap/swapfile" && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
    return 0
  fi
  return 1
}

refresh_omarchy_legacy_swap_state() {
  OMARCHY_LEGACY_SWAP=0
  if (( IS_OMARCHY && ! HIBERNATION_CONFIGURED )) && omarchy_legacy_swap_present; then
    OMARCHY_LEGACY_SWAP=1
  fi
  return 0
}

is_managed_tune_file() {
  local first
  [[ -f $SYSCTL_FILE ]] || return 1
  IFS= read -r first < "$SYSCTL_FILE" || return 1
  case $first in '# Managed by zram_swap_conf.sh ('*) return 0 ;; esac
  return 1
}

default_swapfile_path() {
  if [[ $ROOT_FS == btrfs ]]; then
    if (( IS_OMARCHY )); then printf '%s' /zramconf-swap/swapfile
    else printf '%s' /swap/swapfile; fi
  else
    printf '%s' /swapfile
  fi
}

preflight() {
  local missing=() c logdir
  [[ $(uname -s) == Linux ]] || die "This script only supports Linux."
  [[ -d /run/systemd/system ]] || die "systemd is not running here. This script needs a systemd-based distro."
  if command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt --container -q 2>/dev/null; then
    die "Containers can't manage zram/swap. Run this on the host system."
  fi
  if grep -qi microsoft /proc/version 2>/dev/null; then
    die "WSL is not supported (no zram/swap control)."
  fi
  for c in awk sed grep df findmnt systemctl swapon swapoff mkswap zramctl dd chmod stat mktemp install tee cut tr ps pkill head tail getent modprobe date lsblk cp mv rm wc dirname mkdir env cat sleep truncate; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  if (( ${#missing[@]} )); then
    die "Missing required tools: ${missing[*]}  (install util-linux / coreutils and retry)"
  fi
  if ! { [[ -d /sys/module/zram ]] || modinfo zram >/dev/null 2>&1 || [[ -e /sys/class/zram-control ]]; }; then
    die "Your kernel has no zram support (module 'zram' not found)."
  fi
  logdir=${TMPDIR:-/tmp}
  if [[ -d $logdir && -w $logdir ]]; then
    LOG_FILE=$(mktemp "${logdir%/}/zram_swap_conf-${TS}.XXXXXX") || LOG_FILE=/dev/null
  else
    LOG_FILE=/dev/null
  fi
  [[ $LOG_FILE == /dev/null ]] || chmod 600 "$LOG_FILE" 2>/dev/null
  printf 'zram_swap_conf.sh %s started %s\n' "$SCRIPT_VERSION" "$(date)" >>"$LOG_FILE"
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    { IFS= read -r OS_ID; IFS= read -r OS_LIKE; IFS= read -r OS_NAME; IFS= read -r _; } < <(
      . /etc/os-release 2>/dev/null
      printf '%s\n' "${ID:-unknown}" "${ID_LIKE:-}" "${PRETTY_NAME:-${NAME:-Linux}}" "${VERSION_ID:-}"
    )
  fi
  [[ -n $OS_ID ]] || OS_ID=unknown
  local ids=" ${OS_ID,,} ${OS_LIKE,,} "
  case $ids in
    *" fedora "*|*" rhel "*|*" centos "*)  FAMILY=fedora ;;
    *" arch "*|*" archlinux "*|*" omarchy "*|*" manjaro "*|*" endeavouros "*|*" cachyos "*|*" garuda "*) FAMILY=arch ;;
    *" debian "*|*" ubuntu "*|*" linuxmint "*|*" kali "*|*" pop "*|*" zorin "*|*" raspbian "*) FAMILY=debian ;;
    *) FAMILY=generic ;;
  esac
  # Omarchy is Arch + Hyprland setup; os-release still says Arch
  if [[ ${OS_ID,,} == omarchy ]] || command -v omarchy-version >/dev/null 2>&1 \
     || [[ -d /usr/share/omarchy || -d "${USER_HOME:-$HOME}/.local/share/omarchy" ]]; then
    OS_NAME="Omarchy (Arch Linux)"; FAMILY=arch; IS_OMARCHY=1
  fi
}

detect_shell() {
  local line pid name depth=0 base
  USER_NAME=${SUDO_USER:-$(id -un 2>/dev/null || echo "${USER:-user}")}
  line=$(getent passwd "$USER_NAME" 2>/dev/null || true)
  LOGIN_SHELL=${line##*:}; LOGIN_SHELL=${LOGIN_SHELL##*/}
  USER_HOME=$(printf '%s' "$line" | cut -d: -f6)
  [[ -n $USER_HOME ]] || USER_HOME=${HOME:-/root}

  # walk up the process tree until we hit an interactive shell
  pid=$PPID; SHELL_NAME=""
  while (( depth < 8 )) && [[ $pid =~ ^[0-9]+$ ]] && (( pid > 1 )); do
    name=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ')
    name=${name#-}
    case $name in
      fish|bash|zsh|dash|sh|ash|ksh|ksh93|mksh|tcsh|csh|yash|nu|nushell|elvish|xonsh|pwsh|rc|es)
        SHELL_NAME=$name; break ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    depth=$(( depth + 1 ))
  done
  [[ -n $SHELL_NAME ]] || SHELL_NAME=${LOGIN_SHELL:-unknown}
  base=$SHELL_NAME

  SHELL_EXTRA=""
  case $base in
    zsh)
      if [[ -n ${ZSH:-} && -d ${ZSH:-/nonexistent} ]] || [[ -d $USER_HOME/.oh-my-zsh ]]; then SHELL_EXTRA="Oh My Zsh"
      elif [[ -d $USER_HOME/.zprezto ]]; then SHELL_EXTRA="Prezto"; fi ;;
    fish)
      if [[ -d $USER_HOME/.local/share/omf || -d $USER_HOME/.config/omf ]]; then SHELL_EXTRA="Oh My Fish"
      elif [[ -f $USER_HOME/.config/fish/functions/fisher.fish ]]; then SHELL_EXTRA="Fisher"; fi ;;
    bash)
      if [[ -d $USER_HOME/.oh-my-bash ]]; then SHELL_EXTRA="Oh My Bash"; fi ;;
  esac
  if [[ -n ${STARSHIP_SHELL:-} ]]; then
    SHELL_EXTRA="${SHELL_EXTRA:+$SHELL_EXTRA + }Starship prompt"
  fi

  if   [[ -n ${KONSOLE_VERSION:-} ]];                 then TERM_NAME="Konsole"
  elif [[ -n ${KITTY_WINDOW_ID:-} ]];                 then TERM_NAME="kitty"
  elif [[ -n ${ALACRITTY_SOCKET:-}${ALACRITTY_LOG:-} ]]; then TERM_NAME="Alacritty"
  elif [[ -n ${WEZTERM_EXECUTABLE:-} ]];              then TERM_NAME="WezTerm"
  elif [[ -n ${GNOME_TERMINAL_SCREEN:-} ]];           then TERM_NAME="GNOME Terminal"
  elif [[ -n ${TERM_PROGRAM:-} ]];                    then TERM_NAME=$TERM_PROGRAM
  else TERM_NAME=${TERM:-unknown}; fi
  DESKTOP=${XDG_CURRENT_DESKTOP:-}
}

gather_info() {
  local kb b
  KERNEL=$(uname -r)
  kb=$(meminfo_kb MemTotal); [[ $kb =~ ^[0-9]+$ ]] || kb=0
  RAM_MIB=$(( kb / 1024 ))
  (( RAM_MIB > 0 )) || die "Could not read RAM size from /proc/meminfo."
  (( RAM_MIB < ZRAM_MIN_MIB )) && ZRAM_MIN_MIB=$RAM_MIB
  # Keep usable RAM and installed RAM separate. Device sizes and user input are
  # capped at MemTotal, which is the amount the running kernel can actually use.
  RAM_CAP_MIB=$RAM_MIB
  if command -v lsmem >/dev/null 2>&1; then
    b=$(lsmem -b --summary=only 2>/dev/null | awk -F: '/online memory/{gsub(/[^0-9]/,"",$2); print $2; exit}')
    if [[ $b =~ ^[0-9]+$ ]]; then
      b=$(( b / 1048576 ))
      # sanity: accept only if it is within +25% of MemTotal
      if (( b >= RAM_MIB && b * 4 <= RAM_MIB * 5 )); then RAM_CAP_MIB=$b; fi
    fi
  fi
  ROOT_FS=$(findmnt -n -o FSTYPE -T / 2>/dev/null | head -n1)
}

# Which physical disk holds a path, and is it an SSD, NVMe, HDD ...?
detect_disk() {
  local path=${1:-/} src line name type rota size tran
  DISK_DEV=""; DISK_KIND="unknown"; DISK_MODEL=""; DISK_SIZE_MIB=0
  src=$(findmnt -n -o SOURCE -T "$path" 2>/dev/null | head -n1)
  src=${src%%\[*}                       # btrfs: /dev/nvme0n1p2[/@] -> /dev/nvme0n1p2
  [[ -b $src ]] || return 0
  # walk from the partition / LUKS / LVM device down to the real disk
  while read -r name type rota size tran; do
    [[ $type == disk ]] || continue
    DISK_DEV=$name; [[ $size =~ ^[0-9]+$ ]] && DISK_SIZE_MIB=$(( size / 1048576 ))
    case $name in
      /dev/nvme*)          DISK_KIND="NVMe SSD" ;;
      /dev/mmcblk*)        DISK_KIND="eMMC / SD card" ;;
      *) if [[ $rota == 0 ]]; then DISK_KIND="SSD"; elif [[ $rota == 1 ]]; then DISK_KIND="HDD"; fi ;;
    esac
    [[ $tran == usb ]] && DISK_KIND="$DISK_KIND (USB)"
    break
  done < <(lsblk -s -n -p -b -r -o NAME,TYPE,ROTA,SIZE,TRAN "$src" 2>/dev/null)
  if [[ -n $DISK_DEV ]]; then
    DISK_MODEL=$(lsblk -n -d -o MODEL "$DISK_DEV" 2>/dev/null | head -n1)
    DISK_MODEL=${DISK_MODEL%"${DISK_MODEL##*[![:space:]]}"}
  fi
}

# Can we make a swap file at all, where, and how big may it be?
swap_precheck() {
  local c d probe line
  SWAP_POSSIBLE=1; SWAP_SKIP=""
  BTRFS_SUBVOL_CHECK_REQUIRED=0
  if [[ -e /run/ostree-booted ]]; then
    SWAP_SKIP="immutable (ostree) system detected"
  fi
  SWAPFILE=$(default_swapfile_path)
  d=$(dirname "$SWAPFILE")
  probe=/; [[ -d $d ]] && probe=$d
  SWAP_FS=$(findmnt -n -o FSTYPE -T "$probe" 2>/dev/null | head -n1)
  [[ -n $SWAP_FS ]] || SWAP_FS=$ROOT_FS
  if [[ -z $SWAP_SKIP ]]; then
    case $SWAP_FS in
      btrfs|ext4|ext3|ext2|xfs) ;;
      *) SWAP_SKIP="swap path filesystem '${SWAP_FS:-unknown}' is not supported for swap files" ;;
    esac
  fi
  if [[ -z $SWAP_SKIP && $SWAP_FS == btrfs ]]; then
    for c in btrfs chattr fallocate; do
      command -v "$c" >/dev/null 2>&1 || { SWAP_SKIP="missing tool '$c' (needed for btrfs swap files)"; break; }
    done
    # A dedicated subvolume keeps the swap file out of ordinary snapshots.
    # An unprivileged Btrfs ioctl can fail with EPERM even for a valid subvolume,
    # so defer authoritative validation to the authenticated preflight.
    if [[ -z $SWAP_SKIP && -d $d ]] && ! btrfs subvolume show "$d" >/dev/null 2>&1; then
      BTRFS_SUBVOL_CHECK_REQUIRED=1
    fi
  fi
  line=$(df -m --output=size,avail -- "$probe" 2>/dev/null | awk 'NR==2{print $1" "$2}')
  read -r FS_SIZE_MIB FS_FREE_MIB <<<"$line"
  [[ ${FS_SIZE_MIB:-} =~ ^[0-9]+$ ]] || FS_SIZE_MIB=0
  [[ ${FS_FREE_MIB:-} =~ ^[0-9]+$ ]] || FS_FREE_MIB=0
  SWAP_MAX_MIB=$(( FS_FREE_MIB - DISK_RESERVE_MIB ))
  (( SWAP_MAX_MIB < 0 )) && SWAP_MAX_MIB=0
  if [[ -z $SWAP_SKIP ]] && (( SWAP_MAX_MIB < SWAP_MIN_MIB )); then
    SWAP_SKIP="not enough free disk space ($(fmt_mib "$FS_FREE_MIB") free, 1 GB must stay free)"
  fi
  [[ -n $SWAP_SKIP ]] && SWAP_POSSIBLE=0
  detect_disk "$probe"
  return 0
}

# floor to whole GB (or to 256 MB steps below 2 GB)
round_down_mib() {
  local m=$1
  if (( m >= 2048 )); then printf '%d' $(( m / 1024 * 1024 )); else printf '%d' $(( m / 256 * 256 )); fi
}

# Recommended sizes for this machine.
#   zram: Omarchy uses RAM-sized default; other systems use min(RAM, 8 GB).
#   swap: overflow only (zram is used first, hibernation is not set up):
#         RAM <= 2 GB -> 2x RAM, <= 8 GB -> = RAM, more -> 4 GB
#         and never more than 25% of the free disk space.
recommend() {
  local ram=$RAM_MIB z s quarter
  z=$ram
  if (( ! IS_OMARCHY )); then
    (( z > 8192 )) && z=8192
    z=$(round_down_mib "$z")
  fi
  (( z < ZRAM_MIN_MIB )) && z=$ZRAM_MIN_MIB
  (( z > ram )) && z=$ram
  REC_ZRAM_MIB=$z

  if (( IS_OMARCHY )); then REC_WHY="Omarchy default: zram = usable RAM"
  else REC_WHY="zram = min(RAM, 8 GB)"; fi
  REC_WHY+="; swap = overflow for when zram is full"
  if (( SWAP_LEAVE_EXISTING || OMARCHY_LEGACY_SWAP )); then
    REC_SWAP_MIB=0
    return 0
  fi

  if   (( ram <= 2048 )); then s=$(( ram * 2 ))
  elif (( ram <= 8192 )); then s=$ram
  else s=4096; fi
  if (( SWAP_POSSIBLE )); then
    quarter=$(( FS_FREE_MIB / 4 ))
    if (( s > quarter )); then s=$quarter; REC_WHY="$REC_WHY (limited to 25% of free space)"; fi
    (( s > SWAP_MAX_MIB )) && s=$SWAP_MAX_MIB
    s=$(round_down_mib "$s")
    (( s < 1024 )) && s=0       # less than 1 GB of disk swap isn't worth it
  else
    s=0
  fi
  REC_SWAP_MIB=$s
}

family_label() {
  case $FAMILY in
    fedora)  printf 'Fedora / RHEL family  (dnf, zram-generator)' ;;
    arch)    printf 'Arch family  (pacman, zram-generator)' ;;
    debian)  printf 'Debian family  (apt, systemd-zram-generator)' ;;
    *)       printf 'Generic systemd  (built-in service mode)' ;;
  esac
}

show_swap_now() {
  local n t s u pr any=0
  while read -r n t s u pr; do
    [[ -n $n ]] || continue
    any=1
    box_kv "Swap now" "$(trunc "$n" 20)  $(fmt_mib $(( s / 1048576 )))  prio $pr"
  done < <(swap_table)
  (( any )) || box_kv "Swap now" "none"
}

system_panel() {
  local desk=""
  [[ -n $DESKTOP ]] && desk="  ·  $DESKTOP"
  (( UTF )) || desk=${desk//·/-}
  box_top "Detected system"
  box_kv "OS"        "$OS_NAME"
  box_kv "Family"    "$(family_label)"
  box_kv "Shell"     "$SHELL_NAME${SHELL_EXTRA:+  ($SHELL_EXTRA)}"
  box_kv "Terminal"  "$TERM_NAME$desk"
  box_kv "Kernel"    "$KERNEL"
  if (( RAM_CAP_MIB > RAM_MIB )); then
    box_kv "RAM"     "$(fmt_mib "$RAM_CAP_MIB") installed  ($(fmt_mib "$RAM_MIB") usable)"
  else
    box_kv "RAM"     "$(fmt_mib "$RAM_MIB")"
  fi
  if [[ -n $DISK_DEV ]]; then
    box_kv "Disk"    "$DISK_KIND  $(fmt_mib "$DISK_SIZE_MIB")  ${DISK_MODEL:-$DISK_DEV}"
  else
    box_kv "Disk"    "unknown"
  fi
  box_kv "Root FS"   "${ROOT_FS:-unknown}"
  box_kv "Swap FS"   "${SWAP_FS:-unknown}  $(fmt_mib "$FS_SIZE_MIB") total, $(fmt_mib "$FS_FREE_MIB") free at $SWAPFILE"
  show_swap_now
  box_bottom
  if [[ $SHELL_NAME != bash && -n $SHELL_NAME ]]; then
    line_dim "Note: you're in ${SHELL_NAME}, but this script runs under bash internally - no problem."
  fi
}

recommend_panel() {
  printf '\n'
  box_top "Recommended for this PC"
  box_kv "zram"      "$(fmt_mib "$REC_ZRAM_MIB")    (allowed: up to $(fmt_mib "$RAM_MIB") usable RAM)"
  if (( SWAP_LEAVE_EXISTING )); then
    box_kv "Swap file" "existing swap preserved for hibernation"
  elif (( OMARCHY_LEGACY_SWAP )); then
    box_kv "Swap file" "existing /swap/swapfile preserved"
  elif (( SWAP_POSSIBLE )); then
    if (( REC_SWAP_MIB > 0 )); then
      box_kv "Swap file" "$(fmt_mib "$REC_SWAP_MIB")    (allowed: up to $(fmt_mib "$SWAP_MAX_MIB"))"
    else
      box_kv "Swap file" "none    (allowed: up to $(fmt_mib "$SWAP_MAX_MIB"))"
    fi
  else
    box_kv "Swap file" "not possible here"
  fi
  box_bottom
  if (( IS_OMARCHY )); then
    line_dim "Omarchy default: zram = usable RAM. Swap file = overflow used only when zram is full."
  else
    line_dim "zram = min(RAM, 8 GB). Swap file = overflow used only when zram is full."
  fi
  if (( SWAP_LEAVE_EXISTING )); then
    line_dim "Hibernation is configured: the existing disk swap setup will be left unchanged."
  elif (( OMARCHY_LEGACY_SWAP )); then
    line_dim "Existing Omarchy /swap/swapfile will be preserved; no second disk swap file will be created."
  else
    line_dim "Swap file limit = free space minus 1 GB, so your disk never fills up."
  fi
  case $DISK_KIND in
    HDD*) line_dim "Your disk is an HDD: disk swap is slow, so zram does most of the work." ;;
    eMMC*) line_dim "eMMC/SD storage wears out with heavy writes - a small swap file (or none) is best." ;;
  esac
  (( SWAP_LEAVE_EXISTING || OMARCHY_LEGACY_SWAP || SWAP_POSSIBLE )) || line_warn "No swap file possible: $SWAP_SKIP. Only zram will be set up."
  line_dim "Just press Enter at each question to use the recommended size."
}

# ------------------------------------------------------------------------------
#  Planning / validation
# ------------------------------------------------------------------------------
omarchy_hibernation_configured() {
  [[ -e /etc/mkinitcpio.conf.d/omarchy_resume.conf || -e /etc/limine-entry-tool.d/resume.conf ]]
}

hibernation_configured() {
  local f
  if [[ -r /proc/cmdline ]] && grep -Eq '(^|[[:space:]])resume=[^[:space:]]+' /proc/cmdline; then
    return 0
  fi
  for f in /etc/default/grub /etc/default/limine /etc/kernel/cmdline; do
    if [[ -r $f ]] && grep -Eq '^[[:space:]]*[^#[:space:]].*resume=' "$f"; then return 0; fi
  done
  omarchy_hibernation_configured && return 0
  return 1
}

refresh_hibernation_state() {
  HIBERNATION_CONFIGURED=0
  OMARCHY_HIBERNATION_CONFIGURED=0
  omarchy_hibernation_configured && OMARCHY_HIBERNATION_CONFIGURED=1
  hibernation_configured && HIBERNATION_CONFIGURED=1
  if (( OMARCHY_HIBERNATION_CONFIGURED )); then HIBERNATION_CONFIGURED=1; fi
  # Once detected, preserve the user's existing swap setup for the whole run.
  (( HIBERNATION_CONFIGURED )) && SWAP_LEAVE_EXISTING=1
  return 0
}

plan() {
  PLAN_ERR=""; WARNINGS=(); NOTES=(); REPLACE_FILES=(); ACTIVE_OLD=()
  SWAP_DISABLE_OLD=0
  SWAP_DO=0; SWAP_SKIP=""; SWAPFILE=""
  OMARCHY_TUNE_CLEANUP=0
  local n t s u pr c avail need probe d

  if (( IS_OMARCHY && ! TUNE )) && is_managed_tune_file; then
    OMARCHY_TUNE_CLEANUP=1
    NOTES+=("A previous zram_swap_conf tuning file will be removed so Omarchy's sysctl settings take effect again.")
  fi

  # Refresh free space immediately before validating the requested size.
  swap_precheck
  refresh_hibernation_state
  refresh_omarchy_legacy_swap_state
  recommend
  pick_algo

  # ---- swap file feasibility (swap_precheck already ran) --------------------
  SWAPFILE=$(default_swapfile_path)
  if (( SWAP_LEAVE_EXISTING )); then
    (( SWAP_MIB > 0 )) && NOTES+=("Requested disk swap size ignored because hibernation resume settings were detected.")
    SWAP_MIB=0
    NOTES+=("Hibernation resume settings detected: only zram will be changed; existing swap and /etc/fstab entries will be left untouched.")
    if (( IS_OMARCHY )) && ! grep -q '^HOOKS+=(resume)$' /etc/mkinitcpio.conf.d/omarchy_resume.conf 2>/dev/null \
       && { [[ -e /etc/limine-entry-tool.d/resume.conf ]] || grep -q 'resume=' /etc/default/limine 2>/dev/null; }; then
      NOTES+=("If Omarchy hibernation was removed, delete the stale /etc/limine-entry-tool.d/resume.conf and remove its matching resume= setting from /etc/default/limine; rebuild boot entries if needed, reboot, then rerun to configure disk swap.")
    fi
  elif (( OMARCHY_LEGACY_SWAP )); then
    (( SWAP_MIB > 0 )) && NOTES+=("Requested disk swap size ignored: existing Omarchy /swap/swapfile is being preserved to avoid creating a duplicate.")
    SWAP_MIB=0
    NOTES+=("Existing Omarchy /swap/swapfile detected; it and /etc/fstab will be left untouched, and no second disk swap file will be created.")
  else
    if (( SWAP_MIB > 0 )); then
      if (( SWAP_POSSIBLE )); then SWAP_DO=1
      else WARNINGS+=("Swap file skipped: $SWAP_SKIP. Only zram will be configured."); fi
    else
      if (( SWAP_POSSIBLE )) && { is_swap_active "$SWAPFILE" ||
        awk -v p="$SWAPFILE" '$1 !~ /^#/ && $1 == p && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; }; then
        SWAP_DISABLE_OLD=1
      fi
    fi
  fi
  if (( SWAP_DISABLE_OLD )); then
    NOTES+=("Swap size is 0: $SWAPFILE will be inactive and its file will be kept on disk.")
  fi

  if (( SWAP_DO )); then
    d=$(dirname "$SWAPFILE")
    if [[ -L $d ]]; then PLAN_ERR="$d is a symbolic link; refusing to create a swap file through it."; return 1; fi
    if [[ -e $d && ! -d $d ]]; then PLAN_ERR="$d exists but is not a directory."; return 1; fi
    if [[ -L $SWAPFILE ]]; then PLAN_ERR="$SWAPFILE is a symbolic link; refusing to replace it."; return 1; fi
    if [[ -e $SWAPFILE && ! -f $SWAPFILE ]]; then PLAN_ERR="$SWAPFILE exists but is not a regular file."; return 1; fi
    if [[ -e $SWAPFILE.zramconf-old || -L $SWAPFILE.zramconf-old ]]; then
      PLAN_ERR="$SWAPFILE.zramconf-old already exists; preserve or rename that recovery file before continuing."
      return 1
    fi
    while read -r n t s u pr; do
      # Only replace this script's target file. Other user swap files stay active.
      [[ $t == file && $n == "$SWAPFILE" ]] || continue
      REPLACE_FILES+=("$n"); ACTIVE_OLD+=("$n")
    done < <(swap_table)
    if [[ -e $SWAPFILE ]] && ! in_array "$SWAPFILE" "${REPLACE_FILES[@]}"; then
      if command -v swaplabel >/dev/null 2>&1 && swaplabel "$SWAPFILE" >/dev/null 2>&1; then
        REPLACE_FILES+=("$SWAPFILE")
      else
        PLAN_ERR="$SWAPFILE exists but is not an active or recognizable swap file; refusing to replace possible user data. Move it aside and retry."
        return 1
      fi
    fi
    if [[ $SWAP_FS == btrfs && -d $d && $BTRFS_SUBVOL_CHECK_REQUIRED -eq 1 ]]; then
      NOTES+=("$d could not be inspected without administrator privileges; the script will verify it as a Btrfs subvolume before changing active configuration.")
    fi

    probe=/; [[ -d $d ]] && probe=$d
    avail=$(df -m --output=avail -- "$probe" 2>/dev/null | awk 'NR==2{print $1}')
    [[ $avail =~ ^[0-9]+$ ]] || avail=0
    need=$(( SWAP_MIB + DISK_RESERVE_MIB ))
    if (( avail < need )); then
      PLAN_ERR="Not enough free disk space on $probe: $(fmt_mib "$avail") free, $(fmt_mib "$need") needed (swap + 1 GB that must stay free)."
      return 1
    fi
  else
    if (( SWAP_DISABLE_OLD )); then
      while read -r n t s u pr; do
        [[ $t == file && $n == "$SWAPFILE" ]] || continue
        ACTIVE_OLD+=("$n")
        WARNINGS+=("Existing target swap file $n will be disabled; its file will be kept on disk.")
      done < <(swap_table)
    fi
  fi

  # ---- zram feasibility ------------------------------------------------------
  if [[ -b /dev/zram0 ]] && findmnt -rn -S /dev/zram0 >/dev/null 2>&1; then
    PLAN_ERR="/dev/zram0 is mounted and used as a filesystem - refusing to touch it."
    return 1
  fi
  if [[ -d /sys/block/zram0/holders ]]; then
    local holder
    for holder in /sys/block/zram0/holders/*; do
      [[ -e $holder ]] || continue
      PLAN_ERR="/dev/zram0 is in use by ${holder##*/} - refusing to reset it."
      return 1
    done
  fi
  if (( ZRAM_MIB > RAM_MIB )); then
    PLAN_ERR="zram ($(fmt_mib "$ZRAM_MIB")) exceeds usable RAM ($(fmt_mib "$RAM_MIB"))."
    return 1
  fi

  # Refuse a symlink at the managed drop-in path instead of following it as root.
  if [[ -L $GEN_DROPIN ]]; then
    PLAN_ERR="$GEN_DROPIN is a symbolic link; remove or rename it before continuing."
    return 1
  fi

  # ---- backend ---------------------------------------------------------------
  GEN_INSTALLED=0; GEN_OLD=0
  if gen_present; then
    GEN_INSTALLED=1; BACKEND=generator
    if ! gen_version_ok installed; then GEN_OLD=1; BACKEND=service; fi
  elif [[ $FAMILY != generic ]] && gen_version_ok candidate; then
    BACKEND=generator
  else
    BACKEND=service
  fi
  if (( IS_OMARCHY )) && [[ $BACKEND != generator ]]; then
    PLAN_ERR="Omarchy requires zram-generator for safe activation; the service fallback is disabled to avoid competing with Omarchy's zram migration."
    return 1
  fi

  # ---- informational notes ---------------------------------------------------
  while read -r n t s u pr; do
    [[ -n $n ]] || continue
    case $n in
      /dev/zram0) ;;
      /dev/zram*) WARNINGS+=("$n is another active zram swap device - it will be left untouched.") ;;
      *)
        if [[ $t == partition ]]; then
          WARNINGS+=("Swap partition $n stays active alongside the new setup.")
        elif [[ $t == file && $n != "$SWAPFILE" ]]; then
          WARNINGS+=("Existing swap file $n stays active alongside the new setup.")
        fi
        ;;
    esac
  done < <(swap_table)
  for d in /etc/systemd/zram-generator.conf.d /run/systemd/zram-generator.conf.d /usr/lib/systemd/zram-generator.conf.d; do
    local conf
    for conf in "$d"/*.conf; do
      [[ -e $conf && $conf != "$GEN_DROPIN" ]] || continue
      if lexically_after "${conf##*/}" "${GEN_DROPIN##*/}" || [[ ${conf##*/} == "${GEN_DROPIN##*/}" ]]; then
        WARNINGS+=("Later zram-generator drop-in found in $d - it may override this script's settings.")
        break
      fi
    done
  done
  if [[ $(cat /sys/module/zswap/parameters/enabled 2>/dev/null) == [YyNn1]* ]] \
     && [[ $(cat /sys/module/zswap/parameters/enabled 2>/dev/null) == [Yy1]* ]]; then
    NOTES+=("zswap remains enabled and may add another compressed-swap layer on top of zram; review your kernel setting if that is not intended.")
  fi
  return 0
}

gen_present() {
  [[ -x /usr/lib/systemd/system-generators/zram-generator || -x /lib/systemd/system-generators/zram-generator \
     || -x /usr/libexec/systemd/system-generators/zram-generator ]]
}

# zram-generator older than 1.0 (Ubuntu 22.04 & friends ship 0.3.2) does not
# understand "zram-size = <MiB>", so we use our own service there instead.
gen_version_ok() {  # gen_version_ok installed|candidate
  local v=""
  [[ $FAMILY == debian ]] || return 0
  command -v dpkg >/dev/null 2>&1 || return 0
  if [[ $1 == installed ]]; then
    v=$(dpkg-query -W -f='${Version}' systemd-zram-generator 2>/dev/null) || v=""
    [[ -n $v ]] || return 0
  else
    v=$(apt-cache policy systemd-zram-generator 2>/dev/null | awk '/Candidate:/{print $2; exit}')
    [[ -n $v && $v != "(none)" ]] || return 1
  fi
  dpkg --compare-versions "$v" ge 1.0
}

backend_label() {
  if [[ $BACKEND == generator ]]; then
    if (( GEN_INSTALLED )); then printf 'zram-generator (installed)'; else printf 'zram-generator (will be installed)'; fi
  else
    printf 'built-in systemd service'
    (( GEN_OLD )) && printf ' (zram-generator too old)'
  fi
}

show_review() {
  local f
  printf '\n'
  box_top "Review - nothing has been changed yet"
  box_kv "zram"      "$(fmt_mib "$ZRAM_MIB")   ${ZRAM_ALGO:-kernel default}   priority $ZRAM_PRIO"
  if (( SWAP_DO )); then
    box_kv "Swap file" "$(fmt_mib "$SWAP_MIB")   $SWAPFILE   priority $SWAP_PRIO"
    box_kv "Total"     "$(fmt_mib $(( ZRAM_MIB + SWAP_MIB )))  (zram is used first)"
  elif (( SWAP_LEAVE_EXISTING )); then
    box_kv "Swap file" "existing swap preserved (hibernation)"
    box_kv "Total"     "$(fmt_mib "$ZRAM_MIB") + existing swap"
  elif (( OMARCHY_LEGACY_SWAP )); then
    box_kv "Swap file" "existing /swap/swapfile preserved"
    box_kv "Total"     "$(fmt_mib "$ZRAM_MIB") + existing swap"
  else
    box_kv "Swap file" "none"
    box_kv "Total"     "$(fmt_mib "$ZRAM_MIB")"
  fi
  box_kv "Method"    "$(backend_label)"
  if (( TUNE )); then box_kv "Tuning" "swappiness $(tune_swappiness), page-cluster 0 (for zram)"
  else box_kv "Tuning" "not applied"; fi
  box_kv "Distro"    "$(trunc "$OS_NAME" 40)"
  if (( ${#REPLACE_FILES[@]} )); then
    for f in "${REPLACE_FILES[@]}"; do box_kv "Replaces" "$f  (old swap file)"; done
  fi
  box_kv "Backup"    "$BACKUP_DIR"
  box_bottom
  for f in "${WARNINGS[@]}"; do line_warn "$f"; done
  for f in "${NOTES[@]}";    do line_info "$f"; done
}

input_loop() {
  local preset_z=$ARG_ZRAM preset_s=$ARG_SWAP

  while true; do
    phase "Choose your sizes"
    ask_size "How much zram do you want?" \
      "Compressed swap in RAM. Usable RAM: $(fmt_mib "$RAM_MIB"). Recommended: $(fmt_mib "$REC_ZRAM_MIB").  Examples: 8  4G  512M" \
      "$REC_ZRAM_MIB" "$ZRAM_MIN_MIB" "$RAM_MIB" 0 "$preset_z" "your usable RAM"
    ZRAM_MIB=$ASK_RESULT
    if (( SWAP_LEAVE_EXISTING || OMARCHY_LEGACY_SWAP )); then
      if [[ -n $preset_s ]]; then
        if (( SWAP_LEAVE_EXISTING )); then
          line_warn "Ignoring --swap: hibernation is configured; existing swap will be left unchanged."
        else
          line_warn "Ignoring --swap: existing Omarchy /swap/swapfile is preserved to avoid creating a second disk swap file."
        fi
      fi
      SWAP_MIB=0
    elif (( SWAP_POSSIBLE )); then
      ask_size "How big should the swap file on disk be?" \
        "Free space: $(fmt_mib "$FS_FREE_MIB"), allowed up to $(fmt_mib "$SWAP_MAX_MIB"). Recommended: $(fmt_mib "$REC_SWAP_MIB"). 0 = no swap file" \
        "$REC_SWAP_MIB" "$SWAP_MIN_MIB" "$SWAP_MAX_MIB" 1 "$preset_s" "your free disk space minus 1 GB"
      SWAP_MIB=$ASK_RESULT
    else
      SWAP_MIB=0
      [[ -n $preset_s && $preset_s != 0 ]] && line_warn "Ignoring --swap: $SWAP_SKIP."
    fi
    preset_z=""; preset_s=""

    if ! plan; then
      line_err "$PLAN_ERR"
      (( ASSUME_YES )) && exit 1
      continue
    fi
    show_review
    if (( ASSUME_YES )); then return 0; fi
    while true; do
      printf '\n  %s[Y]%s apply   %s[C]%s change sizes   %s[T]%s tuning on/off   %s[Q]%s quit   %s%s%s ' \
        "$GRN" "$R" "$YEL" "$R" "$BLU" "$R" "$RED" "$R" "$CYN" "$G_PROMPT" "$R"
      read_line || { printf '\n'; line_warn "No input available. Aborting."; exit 130; }
      case ${REPLY_LINE,,} in
        ''|y|yes)          return 0 ;;
        c|change|n|no)     break ;;
        t|tune|tuning)     TUNE=$(( 1 - TUNE ))
                           if (( TUNE )); then line_ok "Tuning will be applied."; else line_info "Tuning turned off."; fi ;;
        q|quit|exit)       line_info "Cancelled - nothing was changed."; exit 0 ;;
        *) line_warn "Please answer Y, C, T or Q." ;;
      esac
    done
  done
}

# Don't pull more pages back into RAM than RAM can hold.
safety_check() {
  local used=0 n t s u pr avail_kb used_kb
  while read -r n t s u pr; do
    [[ $u =~ ^[0-9]+$ ]] || u=0
    if [[ $n == /dev/zram0 ]]; then used=$(( used + u ))
    elif in_array "$n" "${ACTIVE_OLD[@]}"; then used=$(( used + u )); fi
  done < <(swap_table)
  avail_kb=$(meminfo_kb MemAvailable); [[ $avail_kb =~ ^[0-9]+$ ]] || avail_kb=0
  used_kb=$(( used / 1024 ))
  if (( used_kb * 100 > avail_kb * 80 )); then
    printf '\n'
    line_err "Not enough free RAM to safely turn off the current swap."
    line_dim "Swap in use: $(fmt_mib $(( used_kb / 1024 )))   Available RAM: $(fmt_mib $(( avail_kb / 1024 )))"
    line_dim "Close some applications and run the script again. Nothing was changed."
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
#  Steps (run in the background through run_step)
# ------------------------------------------------------------------------------
st_backup() {
  local f
  as_root install -d -m 0700 "$BACKUP_DIR" || return 1
  as_root cp -a /etc/fstab "$BACKUP_DIR/fstab" || return 1
  for f in "$GEN_DROPIN" /etc/default/zramswap "$SVC_FILE" "$SVC_BIN" "$SVC_CONF" "$SYSCTL_FILE"; do
    if [[ -e $f ]]; then as_root cp -a "$f" "$BACKUP_DIR/$(basename "$f")" || return 1; fi
  done
  if [[ -d /etc/systemd/zram-generator.conf.d ]]; then
    as_root cp -a /etc/systemd/zram-generator.conf.d "$BACKUP_DIR/zram-generator.conf.d" || return 1
  fi
  swapon --show 2>&1 | as_root tee "$BACKUP_DIR/swapon-before.txt" >/dev/null
  return 0
}

st_stop_conflicts() {
  local u en ac rec
  for u in "${CONFLICT_UNITS[@]}" "$SVC_NAME"; do
    en=$(systemctl is-enabled "$u" 2>/dev/null) || true
    ac=$(systemctl is-active "$u" 2>/dev/null) || true
    rec=""
    [[ $en == enabled* ]] && rec+="enabled "
    [[ $ac == active ]]   && rec+="active "
    [[ -n $rec ]] || continue
    echo "stopping $u ($rec)"
    printf '%s %s\n' "$u" "$rec" | as_root tee -a "$BACKUP_DIR/disabled-units" >/dev/null
    as_root systemctl disable --now "$u" || as_root systemctl stop "$u" || true
  done
  return 0
}

st_zram_off() {
  as_root systemctl stop dev-zram0.swap || true
  as_root systemctl stop systemd-zram-setup@zram0.service || true
  if is_swap_active /dev/zram0; then as_root swapoff /dev/zram0 || return 1; fi
  if [[ -b /dev/zram0 ]]; then
    as_root zramctl --reset /dev/zram0 || return 1
  fi
  return 0
}

st_retire_files() {
  local f
  for f in "${REPLACE_FILES[@]}"; do
    if is_swap_active "$f"; then as_root swapoff "$f" || return 1; fi
    as_root mv -f "$f" "$f.zramconf-old" || return 1
  done
  return 0
}

st_disable_target_swap() {
  local f
  for f in "${ACTIVE_OLD[@]}"; do
    in_array "$f" "${REPLACE_FILES[@]}" && continue
    if is_swap_active "$f"; then as_root swapoff "$f" || return 1; fi
  done
  return 0
}

st_modprobe() { as_root modprobe zram; }

# swappiness > 100 is only accepted by kernel 5.8+
tune_swappiness() {
  local maj min
  IFS=. read -r maj min _ <<<"$KERNEL"
  min=${min%%[!0-9]*}
  if (( ${maj:-0} > 5 || ( ${maj:-0} == 5 && ${min:-0} >= 8 ) )); then echo 180; else echo 100; fi
}

# Values from the ArchWiki / Pop!_OS zram tuning (vm.page-cluster=0 etc.)
st_tune() {
  local kv key val f out
  out="# Managed by zram_swap_conf.sh ($TS) - zram tuning. Delete this file to undo."$'\n'
  # remember the current runtime values for rollback
  for key in swappiness watermark_boost_factor watermark_scale_factor page-cluster; do
    [[ -r /proc/sys/vm/$key ]] && printf 'vm.%s=%s\n' "$key" "$(<"/proc/sys/vm/$key")"
  done | as_root tee "$BACKUP_DIR/sysctl-before" >/dev/null
  for kv in "vm.swappiness=$(tune_swappiness)" vm.watermark_boost_factor=0 \
            vm.watermark_scale_factor=125 vm.page-cluster=0; do
    key=${kv%%=*}; val=${kv#*=}; f=/proc/sys/vm/${key#vm.}
    if [[ ! -e $f ]]; then echo "skip $key (not in this kernel)"; continue; fi
    out+="$key = $val"$'\n'
    printf '%s\n' "$val" | as_root tee "$f" >/dev/null || echo "could not set $key now (applies after reboot)"
  done
  printf '%s' "$out" | as_root tee "$SYSCTL_FILE" >/dev/null || return 1
  as_root chmod 644 "$SYSCTL_FILE"
}

# Remove only this script's previous tuning on Omarchy when tuning is not
# requested. Reload systemd-sysctl so Omarchy's packaged values take effect now.
st_remove_own_tune() {
  local key
  is_managed_tune_file || return 0
  for key in swappiness watermark_boost_factor watermark_scale_factor page-cluster; do
    [[ -r /proc/sys/vm/$key ]] && printf 'vm.%s=%s\n' "$key" "$(<"/proc/sys/vm/$key")"
  done | as_root tee "$BACKUP_DIR/sysctl-before" >/dev/null || return 1
  as_root rm -f "$SYSCTL_FILE" || return 1
  as_root systemctl restart systemd-sysctl.service
}

pick_algo() {
  local f=/sys/block/zram0/comp_algorithm avail=""
  [[ -r $f ]] && avail=$(<"$f")
  avail=${avail//[][]/}
  ZRAM_ALGO=""
  if [[ " $avail " == *" zstd "* ]]; then ZRAM_ALGO=zstd
  elif [[ " $avail " == *" lz4 "* ]]; then ZRAM_ALGO=lz4
  elif [[ " $avail " == *" lzo-rle "* ]]; then ZRAM_ALGO=lzo-rle
  elif [[ " $avail " == *" lzo "* ]]; then ZRAM_ALGO=lzo
  fi
}

st_install_gen() {
  case $FAMILY in
    fedora) as_root dnf install -y zram-generator || return 1 ;;
    arch) as_root pacman -S --needed --noconfirm -- zram-generator || return 1 ;;
    debian)
      as_root env DEBIAN_FRONTEND=noninteractive apt-get update -qq || echo "note: apt-get update failed, trying anyway"
      as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-zram-generator || return 1 ;;
    *) return 1 ;;
  esac
  if (( DRY_RUN )); then return 0; fi
  gen_present || return 1
  gen_version_ok installed || { echo "installed zram-generator is older than 1.0"; return 1; }
}

write_service_files() {
  as_root mkdir -p "$(dirname "$SVC_CONF")" "$(dirname "$SVC_BIN")" "$(dirname "$SVC_FILE")" || return 1
  printf 'SIZE_MIB=%s\nALGO=%s\nPRIO=%s\n' "$ZRAM_MIB" "$ZRAM_ALGO" "$ZRAM_PRIO" \
    | as_root tee "$SVC_CONF" >/dev/null || return 1
  as_root tee "$SVC_BIN" >/dev/null <<'EOS' || return 1
#!/bin/sh
# Managed by zram_swap_conf.sh - re-run that script to change the size.
CONF=/etc/zram-swap-conf.conf
STATE=/run/zram-swap-conf.dev
[ -r "$CONF" ] && . "$CONF"
: "${SIZE_MIB:?missing SIZE_MIB}"
ALGO=${ALGO:-}
PRIO=${PRIO:-100}
case "$1" in
  start)
    modprobe zram || exit 1
    if [ -n "$ALGO" ]; then
      dev=$(zramctl --find --algorithm "$ALGO" --size "${SIZE_MIB}M" 2>/dev/null) \
        || dev=$(zramctl --find --size "${SIZE_MIB}M") || exit 1
    else
      dev=$(zramctl --find --size "${SIZE_MIB}M") || exit 1
    fi
    if ! mkswap "$dev" >/dev/null 2>&1 || ! swapon --priority "$PRIO" "$dev"; then
      zramctl --reset "$dev" 2>/dev/null
      exit 1
    fi
    echo "$dev" > "$STATE" || {
      swapoff "$dev" 2>/dev/null
      zramctl --reset "$dev" 2>/dev/null
      exit 1
    }
    ;;
  stop)
    [ -r "$STATE" ] || exit 0
    dev=$(cat "$STATE")
    if swapon --noheadings --raw --show=NAME | grep -Fxq "$dev"; then
      swapoff "$dev" || exit 1
    fi
    zramctl --reset "$dev" || exit 1
    rm -f "$STATE"
    ;;
  *) echo "usage: $0 start|stop" >&2; exit 2 ;;
esac
exit 0
EOS
  as_root chmod 755 "$SVC_BIN" || return 1
  as_root tee "$SVC_FILE" >/dev/null <<EOS || return 1
[Unit]
Description=zram swap (configured by zram_swap_conf.sh)
DefaultDependencies=no
After=systemd-modules-load.service
Before=swap.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$SVC_BIN start
ExecStop=$SVC_BIN stop

[Install]
WantedBy=swap.target
EOS
  as_root chmod 644 "$SVC_FILE"
}

st_write_conf() {
  if [[ $BACKEND == generator ]]; then
    as_root mkdir -p "$(dirname "$GEN_DROPIN")" || return 1
    {
      printf '%s\n' \
        "# Managed by zram_swap_conf.sh ($TS). Remove this file to undo." \
        "[zram0]" \
        "zram-size = $ZRAM_MIB" \
        "zram-fraction = 1" \
        "max-zram-size = $ZRAM_MIB"
      [[ -n $ZRAM_ALGO ]] && printf 'compression-algorithm = %s\n' "$ZRAM_ALGO"
      printf '%s\n' "swap-priority = $ZRAM_PRIO" "fs-type = swap"
    } | as_root tee "$GEN_DROPIN" >/dev/null || return 1
    as_root chmod 644 "$GEN_DROPIN"
  else
    # Always reserve zram0 for our service, including when the generator is
    # currently absent and may be installed by a later distro migration.
    # These legacy zero-size options are understood by old and new generators.
    as_root mkdir -p "$(dirname "$GEN_DROPIN")" || return 1
    printf '%s\n' \
      "# Managed by zram_swap_conf.sh ($TS): the service owns zram0." \
      "[zram0]" \
      "zram-fraction = 0" \
      "max-zram-size = 0" \
      | as_root tee "$GEN_DROPIN" >/dev/null || return 1
    as_root chmod 644 "$GEN_DROPIN" || return 1
    write_service_files
  fi
}

label_swapfile() {
  # Fedora/RHEL (SELinux): label only this file; avoid changing policy rules or
  # recursively relabeling a directory that may contain unrelated files.
  if command -v selinuxenabled >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    if command -v restorecon >/dev/null 2>&1; then
      as_root restorecon -F "$SWAPFILE" 2>/dev/null || true
    fi
    if command -v chcon >/dev/null 2>&1; then
      case $(stat -c %C "$SWAPFILE" 2>/dev/null) in
        *swapfile_t*) ;;
        *) as_root chcon -t swapfile_t "$SWAPFILE" 2>/dev/null || true ;;
      esac
    fi
  fi
  return 0
}

st_validate_btrfs_target() {
  local d
  [[ $SWAP_FS == btrfs ]] || return 0
  d=$(dirname "$SWAPFILE")
  [[ -d $d ]] || return 0
  as_root btrfs subvolume show "$d" >/dev/null 2>&1 || {
    echo "$d exists but is not a verifiable Btrfs subvolume; move it aside and retry."
    return 1
  }
}

st_swapfile_create() {
  local f=$SWAPFILE d
  d=$(dirname "$f")
  if [[ $SWAP_FS == btrfs ]]; then
    if [[ ! -e $d ]]; then
      as_root btrfs subvolume create "$d" || return 1
      if (( ! DRY_RUN )); then
        as_root touch "$BACKUP_DIR/btrfs-subvolume-created" || {
          as_root btrfs subvolume delete "$d" >/dev/null 2>&1 || true
          return 1
        }
      fi
    else
      st_validate_btrfs_target || return 1
    fi
  fi
  if (( ! DRY_RUN )) && [[ -e $f ]]; then echo "refusing to overwrite existing $f"; return 1; fi
  as_root install -m 0600 -o root -g root /dev/null "$f" || return 1
  # run_step executes this function in a subshell, so persist rollback state
  # in the per-run backup directory instead of relying on a shell variable.
  if (( ! DRY_RUN )); then
    as_root touch "$BACKUP_DIR/swapfile-created" || {
      as_root rm -f "$f" || true
      return 1
    }
  fi
  if [[ $SWAP_FS == btrfs ]]; then
    # Btrfs requires an empty file to be marked NOCOW before allocation.
    as_root chattr +C "$f" || return 1
    as_root btrfs property set "$f" compression none 2>/dev/null || true
    as_root fallocate -l "${SWAP_MIB}M" "$f" || return 1
  else
    if command -v fallocate >/dev/null 2>&1; then
      if ! as_root fallocate -l "${SWAP_MIB}M" "$f"; then
        echo "fallocate failed; writing the swap file with dd instead"
        as_root truncate -s 0 "$f" || return 1
        as_root dd if=/dev/zero of="$f" bs=1M count="$SWAP_MIB" conv=fsync status=none || return 1
      fi
    else
      as_root dd if=/dev/zero of="$f" bs=1M count="$SWAP_MIB" conv=fsync status=none || return 1
    fi
  fi
  as_root chmod 600 "$f" || return 1
  as_root mkswap "$f" || return 1
  label_swapfile
  return 0
}

st_fstab() {
  local tmp new lines_before lines_after paths
  tmp=$(mktemp) || return 1
  paths=$(printf '%s\n' "$SWAPFILE" "${REPLACE_FILES[@]}")
  export ZSC_PATHS=$paths ZSC_TS=$TS
  awk '
    BEGIN { n = split(ENVIRON["ZSC_PATHS"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") skip[a[i]] = 1 }
    /^[[:space:]]*#/ { print; next }
    ($1 in skip) && $3 == "swap" { print "# [zram_swap_conf " ENVIRON["ZSC_TS"] "] disabled: " $0; next }
    { print }
  ' /etc/fstab >"$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -n $(tail -c1 "$tmp") ]]; then printf '\n' >>"$tmp"; fi
  if (( SWAP_DO )); then
    printf '%s none swap sw,pri=%s 0 0\n' "$SWAPFILE" "$SWAP_PRIO" >>"$tmp"
  fi
  lines_before=$(wc -l </etc/fstab); lines_after=$(wc -l <"$tmp")
  if (( lines_after < lines_before )); then echo "fstab sanity check failed"; rm -f "$tmp"; return 1; fi
  if (( DRY_RUN )); then
    new=/etc/.fstab.zram_swap_conf.dry-run
  else
    new=$(as_root mktemp /etc/.fstab.zram_swap_conf.XXXXXX) || { rm -f "$tmp"; return 1; }
  fi
  as_root install -m 0644 -o root -g root "$tmp" "$new" || { as_root rm -f "$new"; rm -f "$tmp"; return 1; }
  as_root mv -f "$new" /etc/fstab || { as_root rm -f "$new"; rm -f "$tmp"; return 1; }
  command -v restorecon >/dev/null 2>&1 && as_root restorecon /etc/fstab 2>/dev/null
  rm -f "$tmp"
  as_root systemctl daemon-reload || true
  return 0
}

st_apply_zram() {
  as_root systemctl daemon-reload || return 1
  if [[ $BACKEND == generator ]]; then
    as_root systemctl start systemd-zram-setup@zram0.service || return 1
    as_root systemctl start dev-zram0.swap || return 1
  else
    as_root systemctl enable --now "$SVC_NAME" || return 1
  fi
}

st_swapon() { as_root swapon -p "$SWAP_PRIO" "$SWAPFILE"; }

st_verify() {
  if (( DRY_RUN )); then echo "dry-run: verification skipped"; return 0; fi
  local bad=0 fz=0 fs=0 n t s u pr want diff
  while read -r n t s u pr; do
    if [[ $n == /dev/zram0 ]]; then
      fz=1; want=$(( ZRAM_MIB * 1048576 )); diff=$(( s - want )); (( diff < 0 )) && diff=$(( -diff ))
      (( diff <= 2097152 )) || { echo "zram size is $(( s / 1048576 )) MiB, expected $ZRAM_MIB MiB"; bad=1; }
      [[ $pr == "$ZRAM_PRIO" ]] || { echo "zram priority is $pr, expected $ZRAM_PRIO"; bad=1; }
    elif (( SWAP_DO )) && [[ $n == "$SWAPFILE" ]]; then
      fs=1; want=$(( SWAP_MIB * 1048576 )); diff=$(( s - want )); (( diff < 0 )) && diff=$(( -diff ))
      (( diff <= 2097152 )) || { echo "swap file is $(( s / 1048576 )) MiB, expected $SWAP_MIB MiB"; bad=1; }
    fi
  done < <(swap_table)
  (( fz )) || { echo "/dev/zram0 is not active as swap"; bad=1; }
  if (( SWAP_DO && ! fs )); then echo "$SWAPFILE is not active as swap"; bad=1; fi
  return "$bad"
}

st_verify_persist() {
  if (( DRY_RUN )); then echo "dry-run: persistence check skipped"; return 0; fi
  if [[ $BACKEND == generator ]]; then
    grep -q "^zram-size = $ZRAM_MIB\$" "$GEN_DROPIN" || { echo "zram config missing"; return 1; }
    grep -q "^max-zram-size = $ZRAM_MIB\$" "$GEN_DROPIN" || { echo "zram size cap missing"; return 1; }
  else
    [[ -x $SVC_BIN && -f $SVC_FILE ]] || { echo "service files missing"; return 1; }
    systemctl is-enabled "$SVC_NAME" >/dev/null 2>&1 || { echo "service not enabled"; return 1; }
    grep -q '^zram-fraction = 0$' "$GEN_DROPIN" || { echo "generator disable drop-in missing"; return 1; }
  fi
  if (( SWAP_DO )); then
    grep -Eq "^${SWAPFILE//\//\\/}[[:space:]]+none[[:space:]]+swap" /etc/fstab || { echo "fstab entry missing"; return 1; }
  elif (( SWAP_DISABLE_OLD )); then
    if awk -v p="$SWAPFILE" '$1 !~ /^#/ && $1 == p && $3 == "swap" { found=1 } END { exit !found }' /etc/fstab; then
      echo "disabled swap file is still enabled in /etc/fstab"; return 1
    fi
  fi
  return 0
}

st_cleanup_old() {
  local f
  for f in "${REPLACE_FILES[@]}"; do as_root rm -f "$f.zramconf-old"; done
  return 0
}

st_rollback() {
  local f u flags subvol
  local -a subvol_contents=()
  # new swap file
  if (( ! DRY_RUN )) && [[ -n $SWAPFILE ]] && as_root test -e "$BACKUP_DIR/swapfile-created"; then
    if is_swap_active "$SWAPFILE"; then as_root swapoff "$SWAPFILE" || true; fi
    as_root rm -f "$SWAPFILE" || true
  fi
  if (( ! DRY_RUN )) && [[ -n $SWAPFILE ]] && as_root test -e "$BACKUP_DIR/btrfs-subvolume-created"; then
    subvol=$(dirname "$SWAPFILE")
    if [[ -d $subvol ]] && as_root btrfs subvolume show "$subvol" >/dev/null 2>&1; then
      shopt -s nullglob dotglob
      subvol_contents=("$subvol"/*)
      shopt -u nullglob dotglob
      if (( ${#subvol_contents[@]} == 0 )); then as_root btrfs subvolume delete "$subvol" || true; fi
    fi
  fi
  # old swap files
  for f in "${REPLACE_FILES[@]}"; do
    if as_root test -e "$f.zramconf-old"; then
      as_root rm -f "$f" || true
      as_root mv -f "$f.zramconf-old" "$f" || true
      if in_array "$f" "${ACTIVE_OLD[@]}"; then as_root swapon "$f" || true; fi
    fi
  done
  for f in "${ACTIVE_OLD[@]}"; do
    if ! in_array "$f" "${REPLACE_FILES[@]}" && ! is_swap_active "$f"; then
      as_root swapon "$f" || true
    fi
  done
  # fstab
  if (( FSTAB_TOUCHED )) && as_root test -e "$BACKUP_DIR/fstab"; then
    as_root cp -a "$BACKUP_DIR/fstab" /etc/fstab || true
  fi
  # Stop the newly activated setup before restoring its previous configuration.
  if (( CONF_TOUCHED )); then
    as_root systemctl disable --now "$SVC_NAME" || true
    as_root systemctl stop dev-zram0.swap || true
    as_root systemctl stop systemd-zram-setup@zram0.service || true
    if is_swap_active /dev/zram0; then as_root swapoff /dev/zram0 || true; fi
    if [[ -b /dev/zram0 ]]; then as_root zramctl --reset /dev/zram0 || true; fi
    for f in "$GEN_DROPIN" "$SVC_FILE" "$SVC_BIN" "$SVC_CONF"; do
      if as_root test -e "$BACKUP_DIR/$(basename "$f")"; then
        as_root cp -a "$BACKUP_DIR/$(basename "$f")" "$f" || true
      else
        as_root rm -f "$f" || true
      fi
    done
  fi
  # kernel tuning
  if (( TUNE_TOUCHED )); then
    if as_root test -e "$BACKUP_DIR/$(basename "$SYSCTL_FILE")"; then
      as_root cp -a "$BACKUP_DIR/$(basename "$SYSCTL_FILE")" "$SYSCTL_FILE" || true
    else
      as_root rm -f "$SYSCTL_FILE" || true
    fi
    if as_root test -e "$BACKUP_DIR/sysctl-before"; then
      while IFS='=' read -r k v; do
        [[ $k == vm.* && -n $v ]] || continue
        printf '%s\n' "$v" | as_root tee "/proc/sys/vm/${k#vm.}" >/dev/null || true
      done < <(as_root cat "$BACKUP_DIR/sysctl-before")
    fi
  fi
  as_root systemctl daemon-reload || true
  # units we had stopped
  if as_root test -e "$BACKUP_DIR/disabled-units"; then
    while read -r u flags; do
      [[ -n $u ]] || continue
      if [[ $flags == *enabled* && $flags == *active* ]]; then as_root systemctl enable --now "$u" || true
      elif [[ $flags == *enabled* ]]; then as_root systemctl enable "$u" || true
      else as_root systemctl start "$u" || true; fi
    done < <(as_root cat "$BACKUP_DIR/disabled-units")
  fi
  # generator-managed zram as it was before
  as_root systemctl start dev-zram0.swap 2>/dev/null || true
  return 0
}

# ------------------------------------------------------------------------------
#  Failure / interrupt handling
# ------------------------------------------------------------------------------
do_rollback() {
  (( BACKUP_READY )) || return 0
  (( ROLLED_BACK )) && return 0
  ROLLED_BACK=1
  printf '\n'
  run_step -s "Restoring your previous configuration" st_rollback
  line_info "Backups are in $BACKUP_DIR"
}

fail_and_rollback() {
  printf '\n'
  box_top "Something went wrong"
  box_line "${RED}The setup could not be completed.${R}"
  box_line "Details: $(trunc "$LOG_FILE" 46)"
  box_bottom
  do_rollback
  printf '\n'
  line_err "Failed - rollback was attempted. Check the log and backup directory for any recovery errors."
  line_dim "Full log: $LOG_FILE"
  exit 1
}

on_interrupt() {
  trap '' INT TERM HUP
  if [[ -n $STEP_PID ]]; then
    kill "$STEP_PID" 2>/dev/null
    pkill -P "$STEP_PID" 2>/dev/null
    wait "$STEP_PID" 2>/dev/null
  fi
  (( UI_ANIM )) && printf '\r\e[K\e[?25h'
  printf '\n'
  line_warn "Interrupted."
  if (( BACKUP_READY && ! RUN_DONE )); then do_rollback; fi
  exit 130
}

cleanup() {
  [[ -n $KEEPALIVE_PID ]] && kill "$KEEPALIVE_PID" 2>/dev/null
  (( UI_ANIM )) && printf '\e[?25h'
  return 0
}

must() { "$@" || fail_and_rollback; }

# ------------------------------------------------------------------------------
#  The actual work
# ------------------------------------------------------------------------------
run_all() {
  phase "1/4  Disabling the current setup"
  run_step "Backing up current configuration" st_backup || exit 1
  BACKUP_READY=1
  if (( SWAP_DO )) && [[ $SWAP_FS == btrfs ]]; then
    must run_step "Verifying Btrfs swap subvolume" st_validate_btrfs_target
  fi
  if (( IS_OMARCHY && ! TUNE )) && is_managed_tune_file; then
    TUNE_TOUCHED=1
    must run_step "Removing old script tuning to preserve Omarchy settings" st_remove_own_tune
  fi
  must run_step -s "Stopping other zram services" st_stop_conflicts
  must run_step "Turning off current zram swap" st_zram_off
  if (( SWAP_DISABLE_OLD && ${#ACTIVE_OLD[@]} )); then
    must run_step "Disabling the selected swap file" st_disable_target_swap
  fi
  if (( SWAP_DO && ${#REPLACE_FILES[@]} )); then
    must run_step "Retiring old swap file" st_retire_files
  fi

  phase "2/4  Configuring"
  must run_step "Loading the zram kernel module" st_modprobe
  pick_algo
  if [[ $BACKEND == generator && $GEN_INSTALLED -eq 0 ]]; then
    if run_step -s "Installing zram-generator" st_install_gen; then
      GEN_INSTALLED=1
    else
      if (( IS_OMARCHY )); then
        line_err "Could not install zram-generator on Omarchy. Run 'omarchy update', then rerun this script."
        fail_and_rollback
      fi
      BACKEND=service
      line_info "Using the built-in systemd service instead (works on any distro)."
    fi
  fi
  CONF_TOUCHED=1
  must run_step "Writing zram config  ($(fmt_mib "$ZRAM_MIB"), ${ZRAM_ALGO:-kernel default})" st_write_conf
  if (( SWAP_DO )); then
    PROG_FILE=$SWAPFILE; PROG_TOTAL=$(( SWAP_MIB * 1048576 ))
    must run_step "Creating $(fmt_mib "$SWAP_MIB") swap file" st_swapfile_create
    PROG_FILE=""; PROG_TOTAL=0
  fi

  if (( TUNE )); then
    TUNE_TOUCHED=1
    run_step -s "Applying zram kernel tuning (swappiness $(tune_swappiness))" st_tune
  fi

  phase "3/4  Saving permanently and activating"
  if (( SWAP_DO || SWAP_DISABLE_OLD )); then
    FSTAB_TOUCHED=1
    if (( SWAP_DO )); then
      must run_step "Adding swap file to /etc/fstab" st_fstab
    else
      must run_step "Disabling swap file in /etc/fstab" st_fstab
    fi
  fi
  must run_step "Activating zram" st_apply_zram
  if (( SWAP_DO )); then
    must run_step "Activating swap file" st_swapon
  fi

  phase "4/4  Verifying"
  must run_step "Checking saved configuration" st_verify_persist
  if ! run_step -s "Checking live swap devices" st_verify; then LIVE_OK=0; fi
  if (( SWAP_DO && ${#REPLACE_FILES[@]} )); then
    run_step -s "Removing old swap file" st_cleanup_old
  fi
  RUN_DONE=1
}

show_result() {
  local n t s u pr
  printf '\n'
  if (( LIVE_OK )); then
    box_top "All done"
    if (( SWAP_DO )); then
      box_line "${GRN}${G_OK}${R} ${B}zram and swap are configured and saved permanently.${R}"
    elif (( SWAP_LEAVE_EXISTING )); then
      box_line "${GRN}${G_OK}${R} ${B}zram is saved; existing swap was left unchanged for hibernation.${R}"
    elif (( OMARCHY_LEGACY_SWAP )); then
      box_line "${GRN}${G_OK}${R} ${B}zram is saved; existing Omarchy swap was left unchanged.${R}"
    else
      box_line "${GRN}${G_OK}${R} ${B}zram is saved permanently; no disk swap file is selected.${R}"
    fi
  else
    box_top "Saved - reboot needed to finish"
    box_line "${YEL}${G_WARN}${R} ${B}Saved permanently, but live values differ.${R}"
    box_line "${D}A reboot will apply everything. See the log for details.${R}"
  fi
  box_line ""
  box_kv "zram"      "$(fmt_mib "$ZRAM_MIB")   ${ZRAM_ALGO:-kernel default}   priority $ZRAM_PRIO"
  if (( SWAP_DO )); then
    box_kv "Swap file" "$(fmt_mib "$SWAP_MIB")   $SWAPFILE   priority $SWAP_PRIO"
    box_kv "Total"     "$(fmt_mib $(( ZRAM_MIB + SWAP_MIB )))"
  elif (( SWAP_LEAVE_EXISTING )); then
    box_kv "Swap file" "existing setup left unchanged"
  elif (( OMARCHY_LEGACY_SWAP )); then
    box_kv "Swap file" "existing /swap/swapfile left unchanged"
  fi
  box_kv "Method"    "$([[ $BACKEND == generator ]] && echo zram-generator || echo systemd service)"
  (( TUNE )) && box_kv "Tuning" "$SYSCTL_FILE"
  box_bottom

  if (( ! DRY_RUN )); then
    printf '\n  %sCurrent swap devices%s\n' "$B" "$R"
    while read -r n t s u pr; do
      [[ -n $n ]] || continue
      printf '   %s%s%s  %-18s %9s   priority %s\n' "$CYN" "$G_DOT" "$R" "$n" "$(fmt_mib $(( s / 1048576 )))" "$pr"
    done < <(swap_table)
  fi

  printf '\n'
  box_top "Recommendation"
  box_line "${YEL}${G_WARN}${R} ${B}Reboot recommended${R} to confirm everything starts cleanly."
  box_bottom
  for n in "${NOTES[@]}"; do line_info "$n"; done
  printf '\n'
  line_dim "Backup of your old config: $BACKUP_DIR"
  line_dim "Log file: $LOG_FILE"
  line_dim "After reboot check with:  swapon --show   and   zramctl"
  if (( ASSUME_YES || DRY_RUN )); then printf '\n'; return 0; fi
  printf '\n  Reboot now? %s[y/N]%s %s%s%s ' "$D" "$R" "$CYN" "$G_PROMPT" "$R"
  if read_line; then
    case ${REPLY_LINE,,} in
      y|yes) line_info "Rebooting..."; sleep 1; as_root systemctl reboot ;;
      *)     line_info "OK - remember to reboot when convenient." ;;
    esac
  else
    printf '\n'
  fi
}

# ------------------------------------------------------------------------------
#  main
# ------------------------------------------------------------------------------
main() {
  parse_args "$@"
  setup_ui
  trap cleanup EXIT
  trap on_interrupt INT TERM HUP
  if (( ASSUME_YES == 0 )) && ! have_tty_input; then
    die "No terminal available for questions. Use --yes with --zram and optionally --swap, or run this in a terminal."
  fi
  detect_shell
  preflight
  detect_os
  if (( IS_OMARCHY )); then
    (( TUNE_SPECIFIED )) || TUNE=0
  fi
  gather_info
  refresh_hibernation_state
  swap_precheck
  refresh_omarchy_legacy_swap_state
  recommend
  banner
  system_panel
  recommend_panel
  input_loop
  safety_check || exit 1
  authenticate
  run_all
  show_result
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
