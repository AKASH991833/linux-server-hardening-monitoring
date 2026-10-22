# shellcheck shell=bash
# Storage (fstab, RAID, LVM) and cron hygiene. RAID/LVM checks are live-only; fstab and cron checks also work on --root images.

_fstab_file() { rp /etc/fstab; }
_fstab_rows() { # prints "lineno<TAB>fields..." for active lines
  awk '!/^[[:space:]]*(#|$)/ {print NR "\t" $0}' "$(_fstab_file)"
}

register STO-001 medium STORAGE "fstab is valid (4-6 fields, no 'default' typo, no duplicate mountpoints, sane fsck pass)"
chk_STO_001() {
  [[ -r $(_fstab_file) ]] || { DETAIL="no /etc/fstab"; return 2; }
  local n bad="" ln dev mp fs opt dump pass rest; local -A seen
  while IFS=$'\t' read -r ln rest; do
    local -a f; read -ra f <<<"$rest"; n=${#f[@]}
    if (( n < 4 || n > 6 )); then bad+="line$ln(${n}fields) "; continue; fi
    dev=${f[0]}; mp=${f[1]}; fs=${f[2]}; opt=${f[3]}; dump=${f[4]:-0}; pass=${f[5]:-0}
    [[ $opt == default || $opt == *,default || $opt == default,* || $opt == *,default,* ]] && bad+="line$ln(default-typo) "
    [[ $dump =~ ^[01]$ && $pass =~ ^[012]$ ]] || bad+="line$ln(dump/pass) "
    if [[ $fs != swap && $mp != none ]]; then
      [[ $mp == /* ]] || bad+="line$ln(relative-mountpoint) "
      [[ -n ${seen[$mp]:-} ]] && bad+="line$ln(duplicate:$mp) "; seen[$mp]=1
    fi
  done < <(_fstab_rows)
  DETAIL="${bad:+problems: $bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}

register STO-002 low STORAGE "Secondary mounts use 'nofail' so a missing disk cannot block boot"
chk_STO_002() {
  [[ -r $(_fstab_file) ]] || { DETAIL="no /etc/fstab"; return 2; }
  local ln rest bad="" any=0
  while IFS=$'\t' read -r ln rest; do
    local -a f; read -ra f <<<"$rest"; (( ${#f[@]} >= 4 )) || continue
    case ${f[2]} in swap|tmpfs|proc|sysfs|devpts|nfs|nfs4|cifs|bind|none|vfat|efivarfs) continue;; esac
    [[ ${f[1]} == / || ${f[1]} == /boot* || ${f[1]} == /usr || ${f[1]} == /var ]] && continue
    [[ ,${f[3]}, == *,noauto,* ]] && continue
    any=1; [[ ,${f[3]}, == *,nofail,* ]] || bad+="${f[1]} "
  done < <(_fstab_rows)
  (( any )) || { DETAIL="no secondary mounts"; return 2; }
  DETAIL="${bad:+without nofail: $bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}
fix_STO_002() {
  local f ln rest; f=$(_fstab_file)
  while IFS=$'\t' read -r ln rest; do
    local -a w; read -ra w <<<"$rest"; (( ${#w[@]} >= 4 )) || continue
    case ${w[2]} in swap|tmpfs|proc|sysfs|devpts|nfs|nfs4|cifs|bind|none|vfat|efivarfs) continue;; esac
    [[ ${w[1]} == / || ${w[1]} == /boot* || ${w[1]} == /usr || ${w[1]} == /var ]] && continue
    [[ ,${w[3]}, == *,nofail,* || ,${w[3]}, == *,noauto,* ]] && continue
    fx_note "add nofail to ${w[1]} in /etc/fstab"
    (( DRY )) && continue
    tx_backup "$f"; local tmp; tmp=$(mktemp)
    awk -v mp="${w[1]}" '!/^[[:space:]]*#/ && $2==mp && NF>=4 { $4=$4",nofail" } {print}' OFS='\t' "$f" > "$tmp"; cat "$tmp" > "$f"; rm -f "$tmp"
  done < <(_fstab_rows)
}

register STO-003 high STORAGE "Software RAID (md) arrays are healthy (no degraded array, no failed member)"
chk_STO_003() {
  is_live || { DETAIL="live check only"; return 2; }
  local md=${HK_MDSTAT:-/proc/mdstat}
  [[ -r $md ]] && grep -q '^md' "$md" || { DETAIL="no md arrays"; return 2; }
  local bad="" line name=""
  while IFS= read -r line; do
    [[ $line =~ ^(md[0-9a-zA-Z_]+)[[:space:]]*:[[:space:]]*([a-z-]+) ]] && { name=${BASH_REMATCH[1]}; [[ ${BASH_REMATCH[2]} == inactive ]] && bad+="$name(inactive) "; }
    [[ $line =~ \(F\) && -n $name ]] && bad+="$name(failed-member) "
    if [[ -n $name && $line =~ \[([0-9]+)/([0-9]+)\][[:space:]]*\[[U_]+\] ]] && (( BASH_REMATCH[2] < BASH_REMATCH[1] )); then bad+="$name(degraded ${BASH_REMATCH[2]}/${BASH_REMATCH[1]}) "; fi
  done < "$md"
  DETAIL="${bad:+$bad}"; DETAIL=${DETAIL:-all arrays complete}
  [[ -z $bad ]]
}

register STO-004 medium STORAGE "LVM: volume groups keep >=5% free and no snapshot/thin pool is >=95% full"
chk_STO_004() {
  is_live || { DETAIL="live check only"; return 2; }
  local vgs lvs
  if [[ -n ${HK_LVM_FIXTURE:-} ]]; then vgs=$(cat "$HK_LVM_FIXTURE/vgs.txt" 2>/dev/null); lvs=$(cat "$HK_LVM_FIXTURE/lvs.txt" 2>/dev/null)
  else
    command -v vgs >/dev/null 2>&1 || { DETAIL="lvm2 not installed"; return 2; }
    vgs=$(vgs --noheadings --separator '|' --units b --nosuffix -o vg_name,vg_size,vg_free 2>/dev/null)
    lvs=$(lvs --noheadings --separator '|' --units b --nosuffix -o vg_name,lv_name,lv_attr,data_percent,metadata_percent,origin 2>/dev/null)
  fi
  [[ -n $vgs ]] || { DETAIL="no volume groups"; return 2; }
  local bad="" vg size free x
  while IFS='|' read -r vg size free x; do
    vg=${vg// /}; [[ -n $vg ]] || continue; size=${size// /}; free=${free// /}
    (( size > 0 && free * 100 / size < 5 )) && bad+="VG:$vg(only $((free*100/size))% free) "
  done <<<"$vgs"
  local lv attr dp mp origin
  while IFS='|' read -r vg lv attr dp mp origin; do
    vg=${vg// /}; [[ -n $vg ]] || continue; lv=${lv// /}; attr=${attr// /}; dp=${dp// /}; dp=${dp%%.*}
    [[ ${attr:4:1} == I || ${attr:4:1} == S ]] && { bad+="$vg/$lv(invalid-snapshot) "; continue; }
    [[ $dp =~ ^[0-9]+$ ]] && (( dp >= 95 )) && bad+="$vg/$lv(${dp}%full) "
  done <<<"$lvs"
  DETAIL="${bad:+$bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}

# ---- cron ---------------------------------------------------------------------------------
_cron_system_files() { local f; [[ -f $(rp /etc/crontab) ]] && echo "$(rp /etc/crontab)"; for f in "$(rp /etc/cron.d)"/*; do [[ -f $f ]] && echo "$f"; done; }
_cron_system_jobs() { # prints "file<TAB>runas<TAB>command" for /etc/crontab + cron.d lines
  local f line
  while IFS= read -r f; do
    while IFS= read -r line; do
      line=${line#"${line%%[![:space:]]*}"}; [[ -z $line || $line == \#* || $line =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] && continue
      local -a w; read -ra w <<<"$line"; local ns=5; [[ ${w[0]} == @* ]] && ns=1
      (( ${#w[@]} > ns + 1 )) || continue
      printf '%s\t%s\t%s\n' "${f#"$R"}" "${w[$ns]}" "${w[*]:$((ns+1))}"
    done < "$f"
  done < <(_cron_system_files)
}

register CRN-001 high CRON "Scripts run by system cron jobs are not writable by other users"
chk_CRN_001() {
  local f user cmd bad="" prog m
  while IFS=$'\t' read -r f user cmd; do
    prog=${cmd%% *}; [[ $prog == /* ]] || continue
    local p; p=$(rp "$prog"); [[ -e $p ]] || continue
    m=$(file_mode "$p"); (( 8#$m & 8#002 )) && bad+="$prog($m,as $user) "
  done < <(_cron_system_jobs)
  DETAIL="${bad:+world-writable: $bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}
fix_CRN_001() {
  local f user cmd prog m
  while IFS=$'\t' read -r f user cmd; do
    prog=${cmd%% *}; [[ $prog == /* ]] || continue
    local p; p=$(rp "$prog"); [[ -e $p ]] || continue
    m=$(file_mode "$p"); (( 8#$m & 8#002 )) && fx_chmod o-w "$p"
  done < <(_cron_system_jobs)
  return 0
}

register CRN-002 high CRON "No cron job runs code from /tmp or pipes a download into a shell"
chk_CRN_002() {
  local f user cmd bad=""
  while IFS=$'\t' read -r f user cmd; do
    [[ $cmd == /tmp/* || $cmd == /var/tmp/* || $cmd == /dev/shm/* ]] && bad+="${f##*/}(runs $cmd) "
    [[ $cmd =~ (curl|wget)[^|]*\|[[:space:]]*(ba)?sh ]] && bad+="${f##*/}(download|sh) "
  done < <(_cron_system_jobs)
  DETAIL="${bad:+$bad}"; DETAIL=${DETAIL:-ok}
  [[ -z $bad ]]
}

register CRN-003 medium CRON "cron access is restricted (cron.allow exists, root-owned, not writable by others)"
chk_CRN_003() {
  local a; a=$(rp /etc/cron.allow)
  [[ -e $a ]] || { DETAIL="no /etc/cron.allow: every local user may schedule jobs"; return 1; }
  local m; m=$(file_mode "$a"); DETAIL="mode=$m"
  ! (( 8#$m & 8#022 ))
}
fix_CRN_003() {
  local a; a=$(rp /etc/cron.allow)
  [[ -e $a ]] || printf 'root\n' | fx_write "$a"
  fx_chmod 640 "$a"
}
