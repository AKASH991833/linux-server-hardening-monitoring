# shellcheck shell=bash
# Baseline + drift detection ("what changed since I last trusted this server?")

BASELINE_FILES=(/etc/passwd /etc/group /etc/shadow /etc/sudoers /etc/ssh/sshd_config /etc/crontab /etc/hosts /etc/fstab /etc/login.defs /etc/pam.d/sshd /etc/pam.d/sudo /root/.ssh/authorized_keys)

_snapshot() { # prints the snapshot to stdout
  local f p d
  for f in "${BASELINE_FILES[@]}"; do
    p=$(rp "$f"); [[ -r $p ]] && printf 'FILE\t%s\t%s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "$f"
  done
  for d in "$(rp /etc/sudoers.d)" "$(rp /etc/cron.d)" "$(rp /etc/ssh/sshd_config.d)"; do
    [[ -d $d ]] || continue
    for p in "$d"/*; do [[ -f $p && -r $p ]] && printf 'FILE\t%s\t%s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "${p#"$R"}"; done
  done
  for p in "$(rp /home)"/*/.ssh/authorized_keys; do
    [[ -r $p ]] && printf 'FILE\t%s\t%s\n' "$(sha256sum "$p" | cut -d' ' -f1)" "${p#"$R"}"
  done
  # SUID / SGID inventory
  local dirs=()
  for d in bin sbin usr opt; do [[ -d $(rp /$d) ]] && dirs+=("$(rp /$d)"); done
  (( ${#dirs[@]} )) && find "${dirs[@]}" -xdev -type f -perm /6000 2>/dev/null | sed "s#^$R##" | sort | awk '{print "SUID\t" $0}'
  # accounts that can log in
  [[ -r $(rp /etc/passwd) ]] && awk -F: '$7!~/(nologin|false)$/ && $7!="" {print "USER\t" $1 ":" $3 ":" $7}' "$(rp /etc/passwd)" | sort
  # listening ports (live only)
  if is_live && command -v ss >/dev/null 2>&1; then
    ss -H -tuln 2>/dev/null | awk '{n=split($5,a,":"); print "PORT\t" $1 "/" a[n]}' | sort -u
  fi
}

baseline_file() { printf '%s/baseline-%s.txt' "$STATE" "$(printf '%s' "${R:-live}" | tr '/' '_')"; }

baseline_create() {
  mkdir -p "$STATE"; local f; f=$(baseline_file)
  _snapshot > "$f"
  info "baseline saved: $f  ($(grep -c . "$f") entries: $(grep -c '^FILE' "$f") files, $(grep -c '^SUID' "$f") SUID, $(grep -c '^USER' "$f") login users, $(grep -c '^PORT' "$f") ports)"
}

baseline_drift() { # returns 1 if drift found
  local f cur; f=$(baseline_file)
  [[ -f $f ]] || die "no baseline yet. Run: hk baseline create${R:+ --root $R}"
  cur=$(mktemp); _snapshot > "$cur"
  local n=0 kind a b path
  # changed / removed files
  while IFS=$'\t' read -r kind a path; do
    [[ $kind == FILE ]] || continue
    b=$(awk -F'\t' -v p="$path" '$1=="FILE" && $3==p {print $2}' "$cur")
    if [[ -z $b ]]; then printf '%sREMOVED%s  file    %s\n' "$C_YEL" "$C_OFF" "$path"; n=$((n+1))
    elif [[ $a != "$b" ]]; then printf '%sCHANGED%s  file    %s\n' "$C_RED" "$C_OFF" "$path"; n=$((n+1)); fi
  done < "$f"
  while IFS=$'\t' read -r kind a path; do      # new files
    [[ $kind == FILE ]] || continue
    grep -q -F "$(printf '\t%s' "$path")" <(awk -F'\t' '$1=="FILE"{print "\t" $3}' "$f") || { printf '%sADDED%s    file    %s\n' "$C_RED" "$C_OFF" "$path"; n=$((n+1)); }
  done < "$cur"
  local k
  for k in SUID USER PORT; do
    while IFS= read -r a; do printf '%sADDED%s    %-7s %s\n' "$C_RED$C_BLD" "$C_OFF" "${k,,}" "$a"; n=$((n+1)); done < <(comm -13 <(grep "^$k" "$f" | cut -f2- | sort) <(grep "^$k" "$cur" | cut -f2- | sort))
    while IFS= read -r a; do printf '%sREMOVED%s  %-7s %s\n' "$C_YEL" "$C_OFF" "${k,,}" "$a"; n=$((n+1)); done < <(comm -23 <(grep "^$k" "$f" | cut -f2- | sort) <(grep "^$k" "$cur" | cut -f2- | sort))
  done
  rm -f "$cur"
  if (( n == 0 )); then info "${C_GRN}no drift - system matches the baseline${C_OFF}"; return 0; fi
  info "${C_RED}$n difference(s) from baseline${C_OFF}"; return 1
}
