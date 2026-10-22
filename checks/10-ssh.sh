# shellcheck shell=bash
# SSH daemon hardening checks. IDs follow  AREA-NNN. Each check:  chk_<ID>  (0 pass, 1 fail, 2 skip)  and optional  fix_<ID>.

SSHD_CONF() { rp /etc/ssh/sshd_config; }
SSH_DROPIN() { rp /etc/ssh/sshd_config.d/99-hk-hardening.conf; }

_ssh_need() { [[ -r $(SSHD_CONF) ]] || { DETAIL="sshd_config not found (sshd not installed?)"; return 2; }; }

# helper to define a simple "value must be X" SSH check
_ssh_expect() { # key allowed-regex default-if-missing
  _ssh_need || return 2
  local v; v=$(sshd_get "$1"); v=${v:-$3}
  DETAIL="$1 = $v"
  [[ $v =~ ^($2)$ ]]
}
_ssh_fix() { # key value  (writes our drop-in so the vendor file stays untouched)
  local d; d=$(SSH_DROPIN)
  if [[ -d $(rp /etc/ssh/sshd_config.d) ]] && grep -qE '^\s*Include\s+.*sshd_config\.d' "$(SSHD_CONF)"; then
    fx_set_kv "$d" "$1" "$2"
  else
    fx_set_kv "$(SSHD_CONF)" "$1" "$2"
  fi
}

register SSH-001 high   SSH  "Root login over SSH is disabled"
chk_SSH_001() { _ssh_expect PermitRootLogin 'no|prohibit-password|without-password' 'prohibit-password'; }
fix_SSH_001() { _ssh_fix PermitRootLogin no; }

register SSH-002 high   SSH  "SSH password login is disabled (keys only)"
chk_SSH_002() { _ssh_expect PasswordAuthentication 'no' 'yes'; }
fix_SSH_002() {
  # ANTI-LOCKOUT GUARD: never switch to keys-only if nobody can log in with a key.
  local ok=0 u uid home
  while IFS=: read -r u _ uid _ _ home _; do
    (( uid >= 1000 )) && [[ $u != nobody ]] || continue
    [[ -s $(rp "$home")/.ssh/authorized_keys ]] && ok=1
  done < "$(rp /etc/passwd)"
  if (( ! ok )); then
    printf '    %sREFUSED (anti-lockout):%s no normal user has a non-empty ~/.ssh/authorized_keys.\n' "$C_RED" "$C_OFF"
    printf '    Add a public key first (ssh-copy-id), then run: hk fix SSH-002\n'
    return 3
  fi
  _ssh_fix PasswordAuthentication no
}

register SSH-003 high   SSH  "Empty passwords are not allowed over SSH"
chk_SSH_003() { _ssh_expect PermitEmptyPasswords 'no' 'no'; }
fix_SSH_003() { _ssh_fix PermitEmptyPasswords no; }

register SSH-004 medium SSH  "X11 forwarding is disabled"
chk_SSH_004() { _ssh_expect X11Forwarding 'no' 'no'; }
fix_SSH_004() { _ssh_fix X11Forwarding no; }

register SSH-005 medium SSH  "MaxAuthTries is 4 or less"
chk_SSH_005() {
  _ssh_need || return 2
  local v; v=$(sshd_get MaxAuthTries); v=${v:-6}; DETAIL="MaxAuthTries = $v"
  [[ $v =~ ^[0-9]+$ ]] && (( v <= 4 ))
}
fix_SSH_005() { _ssh_fix MaxAuthTries 3; }

register SSH-006 low    SSH  "LoginGraceTime is 60 seconds or less"
chk_SSH_006() {
  _ssh_need || return 2
  local v; v=$(sshd_get LoginGraceTime); v=${v:-120}; v=${v%s}; DETAIL="LoginGraceTime = $v"
  [[ $v =~ ^[0-9]+$ ]] && (( v > 0 && v <= 60 ))
}
fix_SSH_006() { _ssh_fix LoginGraceTime 30; }

register SSH-007 medium SSH  "Idle SSH sessions are closed (ClientAliveInterval set, CountMax <= 3)"
chk_SSH_007() {
  _ssh_need || return 2
  local i c; i=$(sshd_get ClientAliveInterval); c=$(sshd_get ClientAliveCountMax); i=${i:-0}; c=${c:-3}
  DETAIL="ClientAliveInterval=$i ClientAliveCountMax=$c"
  [[ $i =~ ^[0-9]+$ && $c =~ ^[0-9]+$ ]] && (( i > 0 && i <= 300 && c <= 3 ))
}
fix_SSH_007() { _ssh_fix ClientAliveInterval 300; _ssh_fix ClientAliveCountMax 2; }

register SSH-008 medium SSH  "Only strong SSH ciphers/MACs (no CBC, no MD5/SHA1-96)"
chk_SSH_008() {
  _ssh_need || return 2
  local c m; c=$(sshd_get Ciphers); m=$(sshd_get MACs); DETAIL="Ciphers='${c:-default}' MACs='${m:-default}'"
  [[ -z $c && -z $m ]] && return 0       # modern OpenSSH defaults are fine
  [[ $c =~ cbc|3des|arcfour|blowfish ]] && return 1
  [[ $m =~ md5|sha1-96|umac-64 ]] && return 1
  return 0
}
fix_SSH_008() { _ssh_fix Ciphers "chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"; }

register SSH-009 low    SSH  "A legal warning banner is configured"
chk_SSH_009() { _ssh_need || return 2; local v; v=$(sshd_get Banner); DETAIL="Banner = ${v:-none}"; [[ -n $v && $v != none ]]; }
fix_SSH_009() {
  fx_write "$(rp /etc/issue.net)" <<'B'
Authorized use only. Activity on this system is logged and monitored.
B
  _ssh_fix Banner /etc/issue.net
}

# After SSH fixes on a live server: validate config BEFORE reloading (so we never kill sshd with a typo)
post_ssh() {
  is_live || return 0
  command -v sshd >/dev/null 2>&1 || return 0
  if sshd -t 2>/dev/null; then fx_run systemctl reload ssh || fx_run systemctl reload sshd
  else warn "sshd -t failed after changes - rolling back automatically"; return 1; fi
}
