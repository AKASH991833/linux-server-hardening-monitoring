# shellcheck shell=bash
# hk - common helpers (colors, logging, root-prefix handling, config parsing)

HK_VERSION="2.0.0"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_DIM=$'\e[2m'; C_BLD=$'\e[1m'; C_OFF=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_OFF=""
fi

die()  { printf '%shk: error:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 2; }
warn() { printf '%shk: warning:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
info() { printf '%s\n' "$*"; }

# R is the "root prefix". Normal use: R="" (the real server).
# Offline audit: R=/mnt/image  -> every path below is read from /mnt/image/etc/...
rp() { printf '%s%s' "$R" "$1"; }

# Is this a live (real) system? Live-only checks (sysctl, listening ports, systemd) are skipped otherwise.
is_live() { [[ -z "$R" ]]; }

html_escape() { local s=$1; s=${s//&/&amp;}; s=${s//</&lt;}; s=${s//>/&gt;}; s=${s//\"/&quot;}; printf '%s' "$s"; }
json_escape() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\t'/\\t}; s=${s//$'\r'/}
  printf '%s' "$s"
}

# load /etc/hk/hk.conf (or ./hk.conf or $HK_CONF) - simple KEY=VALUE, sourced only if owned by us/root
load_config() {
  local f
  for f in "${HK_CONF:-}" /etc/hk/hk.conf "$HOME/.config/hk/hk.conf" ./hk.conf; do
    [[ -n "$f" && -r "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

# Effective sshd value. sshd uses the FIRST value it sees, and Include files are read in place.
# usage: sshd_get Keyword  -> prints value (lower-case) or nothing
sshd_get() {
  local key=$1 main
  main=$(rp /etc/ssh/sshd_config)
  [[ -r $main ]] || return 0
  _sshd_flat "$main" 0 | awk -v k="$(printf '%s' "$key" | tr 'A-Z' 'a-z')" '
    tolower($1)=="match" {exit}
    tolower($1)==k { $1=""; sub(/^ +/,""); print tolower($0); exit }'
}
_sshd_flat() {
  local file=$1 depth=$2 line inc f
  (( depth > 5 )) && return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    [[ -z "${line//[[:space:]]/}" ]] && continue
    if [[ $line =~ ^[[:space:]]*[Ii]nclude[[:space:]]+(.*)$ ]]; then
      inc=${BASH_REMATCH[1]}
      [[ $inc == /* ]] && inc=$(rp "$inc") || inc="$(dirname "$file")/$inc"
      for f in $inc; do [[ -r $f ]] && _sshd_flat "$f" $((depth+1)); done
    else
      printf '%s\n' "$line"
    fi
  done < "$file"
}

# key = value reader for files like /etc/login.defs (whitespace sep) -> value
kv_get() { # file key
  [[ -r $1 ]] || return 0
  awk -v k="$2" '/^[[:space:]]*#/ {next} $1==k {print $2; exit}' "$1"
}

# sysctl effective value: live -> sysctl -n; offline -> last assignment in sysctl.conf + sysctl.d
sysctl_get() {
  local key=$1 v f r=""
  if is_live && command -v sysctl >/dev/null 2>&1; then
    sysctl -n "$key" 2>/dev/null && return 0
  fi
  for f in "$(rp /etc/sysctl.conf)" "$(rp /etc/sysctl.d)"/*.conf; do
    [[ -r $f ]] || continue
    v=$(awk -F= -v k="$key" '/^[[:space:]]*[#;]/ {next} { gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2); if ($1==k) val=$2 } END{print val}' "$f")
    [[ -n $v ]] && r=$v
  done
  printf '%s' "${r:-}"
}

file_mode()  { stat -c '%a' "$1" 2>/dev/null; }
file_owner() { stat -c '%U:%G' "$1" 2>/dev/null; }

# is mode $1 at least as strict as $2 ? (no bit set in $1 that is not in $2)
mode_ok() { local a=$((8#$1)) b=$((8#$2)); (( (a & ~b) == 0 )); }
