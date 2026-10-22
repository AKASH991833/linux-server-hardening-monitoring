# shellcheck shell=bash
# File permissions and filesystem hygiene.

register FS-001 high FILES "/etc/ssh/sshd_config is owned by root and mode 600/644 max"
chk_FS_001() {
  local f; f=$(rp /etc/ssh/sshd_config); [[ -e $f ]] || { DETAIL="no sshd_config"; return 2; }
  local m; m=$(file_mode "$f"); DETAIL="mode=$m"; mode_ok "$m" 644 && ! (( (8#$m & 8#022) ))
}
fix_FS_001() { fx_chmod 600 "$(rp /etc/ssh/sshd_config)"; }

register FS-002 medium FILES "cron files are not readable/writable by others"
chk_FS_002() {
  local f bad=""
  for f in "$(rp /etc/crontab)" "$(rp /etc/cron.d)" "$(rp /etc/cron.daily)"; do
    [[ -e $f ]] || continue
    local m; m=$(file_mode "$f")
    if [[ -f $f ]]; then mode_ok "$m" 644 && ! (( 8#$m & 8#022 )) || bad+="${f#"$R"}($m) "; else (( 8#$m & 8#002 )) && bad+="${f#"$R"}($m) "; fi
  done
  DETAIL="${bad:+too open: $bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}
fix_FS_002() { local f; f=$(rp /etc/crontab); [[ -f $f ]] && fx_chmod 600 "$f"; return 0; }

register FS-003 critical FILES "No world-writable files in /etc, /usr, /bin, /sbin"
chk_FS_003() {
  local dirs=() d
  for d in etc usr bin sbin lib; do [[ -d $(rp /$d) ]] && dirs+=("$(rp /$d)"); done
  (( ${#dirs[@]} )) || return 2
  local bad; bad=$(find "${dirs[@]}" -xdev -type f -perm -0002 2>/dev/null | sed "s#^$R##" | head -5 | tr '\n' ' ')
  DETAIL="${bad:+world-writable: $bad}"; DETAIL=${DETAIL:-none}
  [[ -z $bad ]]
}
fix_FS_003() {
  # Safety cap: a big tree (e.g. a conda install under /usr) can hold thousands of such files.
  # Fix the first 200 per run, report the rest, and let the admin review before running again.
  local d f n=0 cap=200
  for d in etc usr bin sbin lib; do [[ -d $(rp /$d) ]] || continue
    while IFS= read -r f; do
      if (( n >= cap )); then echo "  FS-003: cap of $cap files reached, run 'hk fix --apply' again after reviewing" >&2; return 0; fi
      fx_chmod o-w "$f"; n=$((n+1))
    done < <(find "$(rp /$d)" -xdev -type f -perm -0002 2>/dev/null)
  done
}

register FS-004 high FILES "No SUID/SGID files in unusual places (/tmp, /home, /var/tmp, /dev/shm)"
chk_FS_004() {
  local dirs=() d
  for d in tmp home var/tmp dev/shm; do [[ -d $(rp /$d) ]] && dirs+=("$(rp /$d)"); done
  (( ${#dirs[@]} )) || return 2
  local bad; bad=$(find "${dirs[@]}" -xdev -type f -perm /6000 2>/dev/null | sed "s#^$R##" | head -5 | tr '\n' ' ')
  DETAIL="${bad:+SUID/SGID: $bad}"; DETAIL=${DETAIL:-none}
  [[ -z $bad ]]
}
fix_FS_004() {
  local d f
  for d in tmp home var/tmp dev/shm; do [[ -d $(rp /$d) ]] || continue
    while IFS= read -r f; do fx_chmod a-s "$f"; done < <(find "$(rp /$d)" -xdev -type f -perm /6000 2>/dev/null)
  done
}

register FS-005 medium FILES "/tmp is a sticky directory"
chk_FS_005() {
  local d; d=$(rp /tmp); [[ -d $d ]] || return 2
  local m; m=$(stat -c '%a' "$d"); DETAIL="/tmp mode=$m"
  [[ ${#m} -eq 4 && ${m:0:1} =~ [1357] ]]
}
fix_FS_005() { fx_chmod 1777 "$(rp /tmp)"; }

register FS-006 medium FILES "Home directories are not world-readable (750 or stricter)"
chk_FS_006() {
  local h bad=""
  [[ -d $(rp /home) ]] || return 2
  for h in "$(rp /home)"/*/; do [[ -d $h ]] || continue; local m; m=$(file_mode "$h"); (( 8#$m & 8#007 )) && bad+="${h#"$R"}($m) "; done
  DETAIL="${bad:+open homes: $bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}
fix_FS_006() { local h; for h in "$(rp /home)"/*/; do [[ -d $h ]] && (( 8#$(file_mode "$h") & 8#007 )) && fx_chmod o-rwx "${h%/}"; done; return 0; }
