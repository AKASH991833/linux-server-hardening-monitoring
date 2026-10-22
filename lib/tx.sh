# shellcheck shell=bash
# Transactional fixes: every file we touch is copied to a backup first,
# and a manifest records how to undo it. "hk rollback <id>" restores everything.

TX_ID=""; TX_DIR=""; DRY=1

tx_begin() {
  TX_ID=$(date -u +%Y%m%dT%H%M%SZ)-$$
  TX_DIR="$STATE/tx/$TX_ID"
  (( DRY )) && return 0
  mkdir -p "$TX_DIR/files"
  : > "$TX_DIR/manifest.tsv"
  printf '%s' "$R" > "$TX_DIR/root"        # remember WHICH root this transaction changed
  chmod 700 "$STATE" "$STATE/tx" "$TX_DIR" 2>/dev/null || true
}

# remember the original state of $1 (a path under $R)
tx_backup() {
  local p=$1 rel=${1#"$R"}
  (( DRY )) && return 0
  grep -q -F "$(printf '\t%s\t' "$rel")" "$TX_DIR/manifest.tsv" 2>/dev/null && return 0   # already saved in this tx
  if [[ -d $p ]]; then      # directories: only permissions/owner are changed by hk, never content
    printf 'dir\t%s\t%s\t%s\n' "$rel" "$(stat -c '%a' "$p")" "$(stat -c '%u:%g' "$p")" >> "$TX_DIR/manifest.tsv"
  elif [[ -e $p ]]; then
    mkdir -p "$TX_DIR/files$(dirname "$rel")"
    cp -a "$p" "$TX_DIR/files$rel"
    printf 'present\t%s\t%s\t%s\n' "$rel" "$(stat -c '%a' "$p")" "$(stat -c '%u:%g' "$p")" >> "$TX_DIR/manifest.tsv"
  else
    printf 'absent\t%s\t-\t-\n' "$rel" >> "$TX_DIR/manifest.tsv"
  fi
}

# --- fix primitives (all of them honor dry-run) ---------------------------------------------

fx_note() { printf '    %s%s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# fx_set_kv FILE KEY VALUE [SEP]  : make "KEY<SEP>VALUE" the only active assignment of KEY in FILE
fx_set_kv() {
  local f=$1 k=$2 v=$3 sep=${4:- }
  fx_note "set $k$sep$v in ${f#"$R"}"
  (( DRY )) && return 0
  tx_backup "$f"
  mkdir -p "$(dirname "$f")"; [[ -e $f ]] || : > "$f"
  local tmp; tmp=$(mktemp)
  # comment out old active lines, then append ours at the END of the "global" part (before any Match block)
  awk -v k="$k" -v line="$k$sep$v" '
    BEGIN{done=0}
    /^[[:space:]]*Match[[:space:]]/ && !done { print line; done=1 }
    { s=$0; sub(/^[[:space:]]+/,"",s); split(s,a,/[[:space:]=]+/);
      if (a[1]==k && s !~ /^#/) { print "# hk-disabled: " $0 } else print $0 }
    END{ if(!done) print line }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

fx_chmod() { # MODE FILE
  fx_note "chmod $1 ${2#"$R"}"
  (( DRY )) && return 0
  tx_backup "$2"; chmod "$1" "$2"
}

fx_chown() { # OWNER FILE
  fx_note "chown $1 ${2#"$R"}"
  (( DRY )) && return 0
  tx_backup "$2"; chown "$1" "$2" 2>/dev/null || warn "chown $1 failed (need root?)"
}

# fx_write FILE  (content on stdin) : create/overwrite a whole file
fx_write() {
  local f=$1 content; content=$(cat)
  fx_note "write ${f#"$R"}"
  (( DRY )) && return 0
  tx_backup "$f"; mkdir -p "$(dirname "$f")"; printf '%s\n' "$content" > "$f"
}

fx_remove_line() { # FILE REGEX
  fx_note "remove lines matching /$2/ from ${1#"$R"}"
  (( DRY )) && return 0
  tx_backup "$1"; local tmp; tmp=$(mktemp); grep -v -E -- "$2" "$1" > "$tmp" || true; cat "$tmp" > "$1"; rm -f "$tmp"
}

fx_run() { # live-only side effects like "systemctl reload sshd"
  fx_note "run: $*"
  (( DRY )) && return 0
  is_live || { fx_note "(offline root: skipped)"; return 0; }
  "$@" >/dev/null 2>&1 || warn "command failed: $*"
}

tx_rollback() {
  local id=$1 d="$STATE/tx/$1" st rel mode own
  [[ -d $d ]] || die "no such transaction: $id  (see: hk tx list)"
  [[ -f $d/manifest.tsv ]] || die "transaction $id has no manifest"
  R=$(cat "$d/root" 2>/dev/null || true)     # always roll back the root the tx was made on
  info "rolling back $id on target: ${R:-/ (live system)}"
  # undo in reverse order
  while IFS=$'\t' read -r st rel mode own; do
    case $st in
      present) mkdir -p "$(dirname "$(rp "$rel")")"; cp -a "$d/files$rel" "$(rp "$rel")"
               chown "$own" "$(rp "$rel")" 2>/dev/null || true; chmod "$mode" "$(rp "$rel")" 2>/dev/null || true   # chown first: it clears SUID bits
               info "  restored $rel" ;;
      dir)     chown "$own" "$(rp "$rel")" 2>/dev/null || true; chmod "$mode" "$(rp "$rel")" 2>/dev/null || true; info "  restored $rel (dir permissions)" ;;
      absent)  rm -f "$(rp "$rel")"; info "  removed  $rel (did not exist before)" ;;
    esac
  done < <(tac "$d/manifest.tsv")
  if [[ -z $R && -f $d/sysctl.undo ]] && command -v sysctl >/dev/null 2>&1; then   # live kernel values
    while read -r k v; do sysctl -w "$k=$v" >/dev/null 2>&1 && info "  kernel $k back to $v"; done < "$d/sysctl.undo"
  fi
  mv "$d" "$d.rolled-back"
  info "${C_GRN}rollback of $id complete${C_OFF}"
}

tx_list() {
  [[ -d $STATE/tx ]] || { info "no transactions yet"; return 0; }
  local d
  for d in "$STATE"/tx/*/; do
    [[ -d $d ]] || continue
    printf '%s  (%s files)\n' "$(basename "$d")" "$(wc -l < "$d/manifest.tsv" 2>/dev/null || echo 0)"
  done
}
