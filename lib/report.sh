# shellcheck shell=bash
# Turn results.tsv into text / JSON / HTML. results.tsv columns:
# id  severity  category  status(PASS|FAIL|SKIP)  title  detail  fixable(yes|no)

declare -A SEV_W=([critical]=10 [high]=6 [medium]=3 [low]=1)

compute_score() { # reads $RESULTS ; sets SCORE GRADE N_PASS N_FAIL N_SKIP
  local got=0 tot=0 id sev cat st rest
  N_PASS=0; N_FAIL=0; N_SKIP=0
  while IFS=$'\t' read -r id sev cat st rest; do
    case $st in
      PASS) N_PASS=$((N_PASS+1)); got=$((got+SEV_W[$sev])); tot=$((tot+SEV_W[$sev])) ;;
      FAIL) N_FAIL=$((N_FAIL+1)); tot=$((tot+SEV_W[$sev])) ;;
      SKIP) N_SKIP=$((N_SKIP+1)) ;;
    esac
  done < "$RESULTS"
  if (( tot == 0 )); then SCORE=0; else SCORE=$(( (got * 100 + tot/2) / tot )); fi
  if   (( SCORE >= 90 )); then GRADE=A
  elif (( SCORE >= 80 )); then GRADE=B
  elif (( SCORE >= 70 )); then GRADE=C
  elif (( SCORE >= 50 )); then GRADE=D
  else GRADE=F; fi
}

sev_color() { case $1 in critical) printf '%s' "$C_RED$C_BLD";; high) printf '%s' "$C_RED";; medium) printf '%s' "$C_YEL";; *) printf '%s' "$C_BLU";; esac; }

report_text() {
  local id sev cat st title detail fixable lastcat=""
  printf '%shk %s - security audit%s   target: %s   host: %s   %s\n' "$C_BLD" "$HK_VERSION" "$C_OFF" "${R:-/ (live system)}" "${HK_HOSTNAME:-$(hostname 2>/dev/null || echo unknown)}" "$(date -u +%FT%TZ)"
  while IFS=$'\t' read -r id sev cat st title detail fixable; do
    [[ $cat != "$lastcat" ]] && { printf '\n%s== %s ==%s\n' "$C_BLD" "$cat" "$C_OFF"; lastcat=$cat; }
    case $st in
      PASS) printf ' %s[PASS]%s %-8s %s\n' "$C_GRN" "$C_OFF" "$id" "$title" ;;
      FAIL) printf ' %s[FAIL]%s %-8s %s %s(%s)%s\n' "$(sev_color "$sev")" "$C_OFF" "$id" "$title" "$C_DIM" "$sev" "$C_OFF"
            printf '          %s%s%s\n' "$C_DIM" "$detail" "$C_OFF"
            [[ $fixable == yes ]] && printf '          %sfix: hk fix %s%s\n' "$C_DIM" "$id" "$C_OFF" ;;
      SKIP) printf ' %s[SKIP]%s %-8s %s %s(%s)%s\n' "$C_DIM" "$C_OFF" "$id" "$title" "$C_DIM" "$detail" "$C_OFF" ;;
    esac
  done < "$RESULTS"
  printf '\n%sScore: %s/100  grade %s%s   pass=%s fail=%s skipped=%s\n' "$C_BLD" "$SCORE" "$GRADE" "$C_OFF" "$N_PASS" "$N_FAIL" "$N_SKIP"
}

report_json() {
  local id sev cat st title detail fixable first=1
  printf '{\n  "tool": "hk", "version": "%s", "target": "%s", "host": "%s", "time": "%s",\n' "$HK_VERSION" "$(json_escape "${R:-/}")" "$(json_escape "${HK_HOSTNAME:-$(hostname 2>/dev/null)}")" "$(date -u +%FT%TZ)"
  printf '  "score": %s, "grade": "%s", "pass": %s, "fail": %s, "skipped": %s,\n  "results": [\n' "$SCORE" "$GRADE" "$N_PASS" "$N_FAIL" "$N_SKIP"
  while IFS=$'\t' read -r id sev cat st title detail fixable; do
    (( first )) || printf ',\n'; first=0
    printf '    {"id":"%s","severity":"%s","category":"%s","status":"%s","title":"%s","detail":"%s","fixable":%s}' \
      "$id" "$sev" "$cat" "$st" "$(json_escape "$title")" "$(json_escape "$detail")" "$([[ $fixable == yes ]] && echo true || echo false)"
  done < "$RESULTS"
  printf '\n  ]\n}\n'
}

# sparkline of the last scores from history.csv  (date,score,...)
_spark_points() {
  [[ -s $STATE/history.csv ]] || return 0
  tail -n 20 "$STATE/history.csv" | awk -F, -v w=300 -v h=50 '{s[NR]=$2} END{ n=NR; if(n<2){exit}; for(i=1;i<=n;i++){ x=(i-1)*w/(n-1); y=h-(s[i]*h/100); printf "%.1f,%.1f ", x, y } }'
}

report_html() {
  local id sev cat st title detail fixable col circ=326.7 off
  off=$(awk -v s="$SCORE" -v c="$circ" 'BEGIN{printf "%.1f", c-(c*s/100)}')
  case $GRADE in A|B) col="#22c55e";; C) col="#eab308";; *) col="#ef4444";; esac
  cat <<HTML
<!doctype html><html lang="en"><head><meta charset="utf-8"><title>hk security report</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
:root{--bg:#0f172a;--card:#1e293b;--tx:#e2e8f0;--mut:#94a3b8}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--tx);font:15px/1.5 system-ui,Segoe UI,Roboto,sans-serif;padding:28px}
h1{margin:0 0 4px;font-size:24px}.sub{color:var(--mut);margin-bottom:22px}
.top{display:flex;gap:22px;flex-wrap:wrap;margin-bottom:22px}.card{background:var(--card);border-radius:14px;padding:20px}
.card.ring{position:relative;width:150px;height:150px;padding:0}.ring svg{transform:rotate(-90deg)}.ring .n{position:absolute;inset:0;display:flex;flex-direction:column;align-items:center;justify-content:center}
.ring .n b{font-size:38px}.stats{display:grid;grid-template-columns:repeat(3,110px);gap:12px}.stat b{display:block;font-size:28px}
table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #334155;vertical-align:top}th{color:var(--mut);font-weight:600;font-size:12px;text-transform:uppercase}
.pill{padding:2px 9px;border-radius:99px;font-size:12px;font-weight:700;color:#0f172a}.PASS{background:#22c55e}.FAIL{background:#ef4444}.SKIP{background:#64748b;color:#fff}
.sev-critical{color:#f87171;font-weight:700}.sev-high{color:#fb923c;font-weight:700}.sev-medium{color:#facc15}.sev-low{color:#60a5fa}
code{white-space:nowrap;background:#0f172a;padding:2px 6px;border-radius:6px;color:#a5b4fc}.det{color:var(--mut);font-size:13px}
</style></head><body>
<h1>Linux Hardening Report</h1>
<div class="sub">target: <code>$(html_escape "${R:-/ (live system)}")</code> &middot; host: $(html_escape "${HK_HOSTNAME:-$(hostname 2>/dev/null)}") &middot; $(date -u +%FT%TZ) &middot; hk $HK_VERSION</div>
<div class="top">
 <div class="card ring"><svg width="150" height="150" viewBox="0 0 120 120"><circle cx="60" cy="60" r="52" fill="none" stroke="#334155" stroke-width="11"/>
 <circle cx="60" cy="60" r="52" fill="none" stroke="$col" stroke-width="11" stroke-linecap="round" stroke-dasharray="$circ" stroke-dashoffset="$off"/></svg>
 <div class="n"><b>$SCORE</b><span>grade $GRADE</span></div></div>
 <div class="card stats"><div class="stat"><b style="color:#22c55e">$N_PASS</b>passed</div><div class="stat"><b style="color:#ef4444">$N_FAIL</b>failed</div><div class="stat"><b style="color:#94a3b8">$N_SKIP</b>skipped</div></div>
HTML
  local pts; pts=$(_spark_points)
  if [[ -n $pts ]]; then
    printf ' <div class="card"><div class="sub" style="margin:0 0 6px">Score trend (last runs)</div><svg width="300" height="50" viewBox="0 0 300 50"><polyline fill="none" stroke="#818cf8" stroke-width="2.5" points="%s"/></svg></div>\n' "$pts"
  fi
  printf '</div>\n<div class="card"><table><tr><th>Status</th><th>ID</th><th>Check</th><th>Severity</th><th>Evidence / fix</th></tr>\n'
  while IFS=$'\t' read -r id sev cat st title detail fixable; do
    printf '<tr><td><span class="pill %s">%s</span></td><td><code>%s</code></td><td>%s<br><span class="det">%s</span></td><td class="sev-%s">%s</td><td class="det">%s' \
      "$st" "$st" "$id" "$(html_escape "$title")" "$cat" "$sev" "$sev" "$(html_escape "$detail")"
    [[ $st == FAIL && $fixable == yes ]] && printf '<br>fix: <code>hk fix %s</code>' "$id"
    printf '</td></tr>\n'
  done < "$RESULTS"
  printf '</table></div></body></html>\n'
}

record_history() {
  mkdir -p "$STATE" 2>/dev/null || return 0
  printf '%s,%s,%s,%s\n' "$(date -u +%FT%TZ)" "$SCORE" "$N_PASS" "$N_FAIL" >> "$STATE/history.csv" 2>/dev/null || true
}
