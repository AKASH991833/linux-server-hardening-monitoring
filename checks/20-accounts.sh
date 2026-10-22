# shellcheck shell=bash
# Accounts, passwords and sudo.

register ACC-001 critical ACCOUNTS "Only root has UID 0"
chk_ACC_001() {
  local f; f=$(rp /etc/passwd); [[ -r $f ]] || { DETAIL="no /etc/passwd"; return 2; }
  local bad; bad=$(awk -F: '$3==0 && $1!="root" {printf "%s ",$1}' "$f")
  DETAIL="${bad:+extra UID-0 accounts: $bad}"; DETAIL=${DETAIL:-only root has UID 0}
  [[ -z $bad ]]
}

register ACC-002 critical ACCOUNTS "No account has an empty password"
chk_ACC_002() {
  local f; f=$(rp /etc/shadow); [[ -r $f ]] || { DETAIL="/etc/shadow not readable (run as root)"; return 2; }
  local bad; bad=$(awk -F: '$2=="" {printf "%s ",$1}' "$f")
  DETAIL="${bad:+empty password: $bad}"; DETAIL=${DETAIL:-no empty passwords}
  [[ -z $bad ]]
}
fix_ACC_002() {
  local f u; f=$(rp /etc/shadow)
  for u in $(awk -F: '$2=="" {print $1}' "$f"); do
    fx_note "lock account $u (put '!' in password field)"
    (( DRY )) || { tx_backup "$f"; awk -F: -v OFS=: -v u="$u" '$1==u && $2=="" {$2="!"} {print}' "$f" > "$f.hk" && cat "$f.hk" > "$f" && rm -f "$f.hk"; }
  done
}

register ACC-003 high ACCOUNTS "/etc/passwd is 644 and /etc/shadow is 640 or stricter"
chk_ACC_003() {
  local p s; p=$(file_mode "$(rp /etc/passwd)"); s=$(file_mode "$(rp /etc/shadow)")
  [[ -n $p ]] || { DETAIL="no /etc/passwd"; return 2; }
  DETAIL="passwd=$p shadow=${s:-missing}"
  mode_ok "$p" 644 && { [[ -z $s ]] || mode_ok "$s" 640; }
}
fix_ACC_003() { fx_chmod 644 "$(rp /etc/passwd)"; [[ -e $(rp /etc/shadow) ]] && fx_chmod 640 "$(rp /etc/shadow)"; return 0; }

register ACC-004 medium ACCOUNTS "Password maximum age is 90 days or less (login.defs)"
chk_ACC_004() {
  local f v; f=$(rp /etc/login.defs); [[ -r $f ]] || { DETAIL="no login.defs"; return 2; }
  v=$(kv_get "$f" PASS_MAX_DAYS); DETAIL="PASS_MAX_DAYS = ${v:-unset}"
  [[ $v =~ ^[0-9]+$ ]] && (( v > 0 && v <= 90 ))
}
fix_ACC_004() { fx_set_kv "$(rp /etc/login.defs)" PASS_MAX_DAYS 90 " "; }

register ACC-005 medium ACCOUNTS "Password minimum age is 1 day or more (login.defs)"
chk_ACC_005() {
  local f v; f=$(rp /etc/login.defs); [[ -r $f ]] || return 2
  v=$(kv_get "$f" PASS_MIN_DAYS); DETAIL="PASS_MIN_DAYS = ${v:-unset}"
  [[ $v =~ ^[0-9]+$ ]] && (( v >= 1 ))
}
fix_ACC_005() { fx_set_kv "$(rp /etc/login.defs)" PASS_MIN_DAYS 1 " "; }

register ACC-006 medium ACCOUNTS "Default umask is 027 or stricter (login.defs)"
chk_ACC_006() {
  local f v; f=$(rp /etc/login.defs); [[ -r $f ]] || return 2
  v=$(kv_get "$f" UMASK); DETAIL="UMASK = ${v:-unset}"
  [[ $v =~ ^0?[0-7]{3}$ ]] || return 1
  v=$((8#${v#0}))
  (( (v & 8#027) == 8#027 ))
}
fix_ACC_006() { fx_set_kv "$(rp /etc/login.defs)" UMASK 027 " "; }

register ACC-007 medium ACCOUNTS "Password quality: minimum length 12 (pwquality)"
chk_ACC_007() {
  local f v; f=$(rp /etc/security/pwquality.conf)
  [[ -r $f ]] || { DETAIL="pwquality.conf missing (libpam-pwquality not installed)"; return 1; }
  v=$(awk -F= '/^[[:space:]]*#/ {next} /^[[:space:]]*minlen/ {gsub(/[[:space:]]/,"",$2); print $2}' "$f" | tail -1)
  DETAIL="minlen = ${v:-unset}"
  [[ $v =~ ^[0-9]+$ ]] && (( v >= 12 ))
}
fix_ACC_007() { fx_set_kv "$(rp /etc/security/pwquality.conf)" minlen 12 " = "; }

register ACC-008 high ACCOUNTS "sudoers has no blanket NOPASSWD: ALL rule"
chk_ACC_008() {
  local files=() f
  [[ -r $(rp /etc/sudoers) ]] && files+=("$(rp /etc/sudoers)")
  for f in "$(rp /etc/sudoers.d)"/*; do [[ -f $f ]] && files+=("$f"); done
  (( ${#files[@]} )) || { DETAIL="no sudoers file"; return 2; }
  local bad; bad=$(grep -H -E '^[^#]*NOPASSWD:[[:space:]]*ALL' "${files[@]}" 2>/dev/null | sed "s#^$R##" | head -3 | tr '\n' ';')
  DETAIL="${bad:-no NOPASSWD: ALL rules}"
  [[ -z $bad ]]
}

register ACC-009 high ACCOUNTS "No duplicate UIDs"
chk_ACC_009() {
  local f; f=$(rp /etc/passwd); [[ -r $f ]] || return 2
  local d; d=$(cut -d: -f3 "$f" | sort | uniq -d | tr '\n' ' ')
  DETAIL="${d:+duplicate UIDs: $d}"; DETAIL=${DETAIL:-all UIDs unique}
  [[ -z $d ]]
}

register ACC-010 medium ACCOUNTS "System accounts (UID<1000) cannot log in interactively"
chk_ACC_010() {
  local f; f=$(rp /etc/passwd); [[ -r $f ]] || return 2
  local bad; bad=$(awk -F: '$3>0 && $3<1000 && $1!~/^(sync|shutdown|halt)$/ && $7!~/(nologin|false)$/ && $7!="" {printf "%s(%s) ",$1,$7}' "$f")
  DETAIL="${bad:+system accounts with a shell: $bad}"; DETAIL=${DETAIL:-none}
  [[ -z $bad ]]
}
fix_ACC_010() {
  local f; f=$(rp /etc/passwd)
  fx_note "set shell /usr/sbin/nologin for system accounts"
  (( DRY )) && return 0
  tx_backup "$f"
  awk -F: -v OFS=: '$3>0 && $3<1000 && $1!~/^(sync|shutdown|halt)$/ && $7!~/(nologin|false)$/ && $7!="" {$7="/usr/sbin/nologin"} {print}' "$f" > "$f.hk" && cat "$f.hk" > "$f" && rm -f "$f.hk"
}

register ACC-011 medium ACCOUNTS "No .rhosts / .netrc files in home directories"
chk_ACC_011() {
  local d; d=$(rp /home); [[ -d $d ]] || { DETAIL="no /home"; return 2; }
  local bad; bad=$(find "$d" -maxdepth 2 \( -name .rhosts -o -name .netrc -o -name .shosts \) 2>/dev/null | sed "s#^$R##" | tr '\n' ' ')
  DETAIL="${bad:+found: $bad}"; DETAIL=${DETAIL:-none}
  [[ -z $bad ]]
}
