# shellcheck shell=bash
# Health monitoring with flap suppression, cooldown, recovery notices, multiple alert channels
# and a Prometheus textfile export.

# defaults (override in hk.conf)  format: WARN CRIT
declare -A TH=( [load]="80 150" [mem]="85 95" [swap]="50 80" [disk]="80 90" [inode]="80 90" [logins]="20 100" [zombies]="5 20" [units_failed]="1 3" )
HK_CONSECUTIVE=${HK_CONSECUTIVE:-2}       # breaches in a row before the first alert (stops flapping)
HK_COOLDOWN_MIN=${HK_COOLDOWN_MIN:-60}    # repeat reminder for a still-CRITICAL metric after this many minutes
HK_LOGIN_WINDOW_MIN=${HK_LOGIN_WINDOW_MIN:-10}
HK_ALERT_CHANNELS=${HK_ALERT_CHANNELS:-log,stdout}
HK_TELEGRAM_API=${HK_TELEGRAM_API:-https://api.telegram.org}   # override only for tests/mocks

declare -A M            # metric name -> integer value
declare -A SIM          # simulated values

collect_metrics() {
  local cores load1
  cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo); cores=${cores:-1}
  load1=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo 0)
  M[load]=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%d", l*100/c}')   # load as % of CPU cores
  if [[ -r /proc/meminfo ]]; then
    M[mem]=$(awk '/MemTotal/ {t=$2} /MemAvailable/ {a=$2} END{ if(t>0) printf "%d", (t-a)*100/t; else print 0 }' /proc/meminfo)
    M[swap]=$(awk '/SwapTotal/ {t=$2} /SwapFree/ {f=$2} END{ if(t>0) printf "%d", (t-f)*100/t; else print 0 }' /proc/meminfo)
  fi
  local fs pct
  while read -r pct fs; do M["disk:$fs"]=${pct%\%}; done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {print $5, $6}')
  while read -r pct fs; do [[ $pct == "-" ]] || M["inode:$fs"]=${pct%\%}; done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {print $5, $6}')
  M[zombies]=$(ps -eo stat= 2>/dev/null | grep -c '^Z')
  if command -v systemctl >/dev/null 2>&1; then
    M[units_failed]=$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c . || true)
  fi
  M[logins]=$(_failed_logins_count)
  local k; for k in "${!SIM[@]}"; do M[$k]=${SIM[$k]}; done
}

AUTH_LOG=""
_auth_log() {
  [[ -n $AUTH_LOG ]] && { printf '%s' "$AUTH_LOG"; return; }
  local f; for f in "${HK_AUTH_LOG:-}" "$(rp /var/log/auth.log)" "$(rp /var/log/secure)"; do [[ -n $f && -r $f ]] && { printf '%s' "$f"; return; }; done
}
# count "Failed password"/"Invalid user" lines in the last N minutes (ISO or syslog timestamps)
_failed_logins_count() { _failed_logins_lines | grep -c . || true; }
_failed_logins_lines() {
  local f; f=$(_auth_log); [[ -n $f ]] || return 0
  local since_epoch; since_epoch=$(date -d "-${HK_LOGIN_WINDOW_MIN} minutes" +%s)
  grep -E 'Failed password|Invalid user|authentication failure' "$f" 2>/dev/null | while IFS= read -r line; do
    local ts=${line%% *}
    if [[ $ts =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then e=$(date -d "$ts" +%s 2>/dev/null)
    else e=$(date -d "$(echo "$line" | awk '{print $1,$2,$3}')" +%s 2>/dev/null); fi
    [[ -n ${e:-} ]] && (( e >= since_epoch )) && printf '%s\n' "$line"
  done
}
top_attackers() { _failed_logins_lines | grep -oE 'from [0-9a-fA-F:.]+' | awk '{print $2}' | sort | uniq -c | sort -rn | head -${1:-5}; }

_threshold_for() { local m=${1%%:*}; printf '%s' "${TH[$m]:-}"; }

level_of() { # metric value -> OK|WARN|CRIT
  local th w c; th=$(_threshold_for "$1"); [[ -n $th ]] || { echo OK; return; }
  read -r w c <<<"$th"
  if (( $2 >= c )); then echo CRIT; elif (( $2 >= w )); then echo WARN; else echo OK; fi
}

send_alert() { # level metric message
  local lvl=$1 msg="[hk $(hostname 2>/dev/null)] $1: $2"
  local ch
  IFS=, read -ra chans <<<"$HK_ALERT_CHANNELS"
  for ch in "${chans[@]}"; do
    case $ch in
      stdout)   printf '%s ALERT %s\n' "$(date -u +%FT%TZ)" "$msg" ;;
      log)      mkdir -p "$STATE"; printf '%s %s\n' "$(date -u +%FT%TZ)" "$msg" >> "$STATE/alerts.log" ;;
      webhook)  [[ -n ${HK_WEBHOOK_URL:-} ]] && curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"text\":\"$(json_escape "$msg")\",\"level\":\"$lvl\"}" "$HK_WEBHOOK_URL" >/dev/null || warn "webhook failed" ;;
      telegram) # token is read from a FILE (never put tokens in hk.conf or git)
                if [[ -r ${HK_TELEGRAM_TOKEN_FILE:-/nonexistent} && -n ${HK_TELEGRAM_CHAT:-} ]]; then
                  curl -fsS -m 10 "$HK_TELEGRAM_API/bot$(cat "$HK_TELEGRAM_TOKEN_FILE")/sendMessage" --data-urlencode "chat_id=$HK_TELEGRAM_CHAT" --data-urlencode "text=$msg" >/dev/null || warn "telegram failed"
                else warn "telegram channel needs HK_TELEGRAM_TOKEN_FILE and HK_TELEGRAM_CHAT"; fi ;;
      mail)     command -v mail >/dev/null 2>&1 && [[ -n ${HK_MAIL_TO:-} ]] && printf '%s\n' "$msg" | mail -s "$msg" "$HK_MAIL_TO" ;;
    esac
  done
}

monitor_once() {
  local sf="$STATE/monitor.state" now; now=$(date +%s)
  mkdir -p "$STATE"; touch "$sf"
  collect_metrics
  local m v lvl prev_lvl cnt last new_cnt out="" worst=OK
  declare -A NEWSTATE=()
  for m in $(printf '%s\n' "${!M[@]}" | sort); do
    v=${M[$m]}; [[ $v =~ ^[0-9]+$ ]] || continue
    lvl=$(level_of "$m" "$v")
    read -r prev_lvl cnt last < <(awk -F'\t' -v k="$m" '$1==k {print $2, $3, $4}' "$sf"); prev_lvl=${prev_lvl:-OK}; cnt=${cnt:-0}; last=${last:-0}
    if [[ $lvl == OK ]]; then
      new_cnt=0
      if [[ $prev_lvl != OK ]]; then send_alert RECOVERED "$m back to normal ($v)"; fi
      NEWSTATE[$m]=$'OK\t0\t0'
    else
      new_cnt=$((cnt+1))
      local alerted=$last
      if (( new_cnt >= HK_CONSECUTIVE )); then
        if [[ $prev_lvl != "$lvl" ]] || (( last == 0 )); then
          send_alert "$lvl" "$m = $v (warn>=${TH[${m%%:*}]%% *}, crit>=${TH[${m%%:*}]##* })"; alerted=$now
        elif [[ $lvl == CRIT ]] && (( now - last >= HK_COOLDOWN_MIN*60 )); then
          send_alert "$lvl (still)" "$m = $v"; alerted=$now
        fi
      fi
      NEWSTATE[$m]="$lvl"$'\t'"$new_cnt"$'\t'"$alerted"
    fi
    [[ $lvl == CRIT ]] && worst=CRIT; [[ $lvl == WARN && $worst == OK ]] && worst=WARN
    out+=$(printf '%-18s %6s   %s' "$m" "$v" "$lvl")$'\n'
  done
  for m in "${!NEWSTATE[@]}"; do printf '%s\t%s\n' "$m" "${NEWSTATE[$m]}"; done > "$sf"
  printf '%s%s%s\n%s' "$C_BLD" "METRIC               VALUE   STATE" "$C_OFF" "$out" | sed -e "s/CRIT/${C_RED}CRIT${C_OFF}/" -e "s/WARN/${C_YEL}WARN${C_OFF}/"
  local att; att=$(top_attackers 3)
  [[ -n $att ]] && { printf '\nTop failed-login sources (last %s min):\n%s\n' "$HK_LOGIN_WINDOW_MIN" "$att"; }
  write_prom
  [[ $worst == CRIT ]] && return 2; [[ $worst == WARN ]] && return 1; return 0
}

# Prometheus node_exporter "textfile collector" format
write_prom() {
  local f="${HK_PROM_FILE:-$STATE/hk.prom}" m tmp; tmp=$(mktemp)
  {
    echo "# HELP hk_metric Current value of an hk monitored metric"; echo "# TYPE hk_metric gauge"
    for m in $(printf '%s\n' "${!M[@]}" | sort); do [[ ${M[$m]} =~ ^[0-9]+$ ]] && printf 'hk_metric{name="%s"} %s\n' "$m" "${M[$m]}"; done
    [[ -n ${SCORE:-} ]] && { echo "# TYPE hk_audit_score gauge"; echo "hk_audit_score $SCORE"; }
  } > "$tmp"
  mv "$tmp" "$f" 2>/dev/null || cp "$tmp" "$f"
}

monitor_install() { # prints (or installs with --apply) a systemd timer / cron entry
  local mode=$1 apply=$2 bin; bin=$(readlink -f "$0")
  if [[ $mode == systemd ]]; then
    local svc timer
    svc="[Unit]
Description=hk health monitor

[Service]
Type=oneshot
ExecStart=$bin monitor once"
    timer="[Unit]
Description=Run hk health monitor every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target"
    if [[ $apply == 1 ]]; then
      printf '%s\n' "$svc" > /etc/systemd/system/hk-monitor.service; printf '%s\n' "$timer" > /etc/systemd/system/hk-monitor.timer
      systemctl daemon-reload && systemctl enable --now hk-monitor.timer && info "installed hk-monitor.timer"
    else
      printf '# /etc/systemd/system/hk-monitor.service\n%s\n\n# /etc/systemd/system/hk-monitor.timer\n%s\n\n(add --apply to install)\n' "$svc" "$timer"
    fi
  else
    local line="* * * * * $bin monitor once >/dev/null 2>&1"
    if [[ $apply == 1 ]]; then ( crontab -l 2>/dev/null | grep -v 'hk monitor\|monitor once'; echo "$line" ) | crontab - && info "cron entry installed"
    else printf '%s\n(add --apply to install)\n' "$line"; fi
  fi
}
