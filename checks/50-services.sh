# shellcheck shell=bash
# Services, firewall, updates, logging.

_has_pkg_or_unit() { # name  -> installed/enabled evidence; offline: look for binaries/config in R
  local n=$1
  if is_live; then
    command -v "$n" >/dev/null 2>&1 && return 0
    command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files 2>/dev/null | grep -q "^$n\." && return 0
    return 1
  fi
  [[ -e $(rp /etc/$n) || -e $(rp /usr/sbin/$n) || -e $(rp /usr/bin/$n) ]]
}

register SVC-001 high SERVICES "A host firewall is installed (ufw / firewalld / nftables rules)"
chk_SVC_001() {
  local n
  for n in ufw firewalld nftables iptables; do _has_pkg_or_unit "$n" && { DETAIL="found: $n"; return 0; }; done
  DETAIL="no firewall tooling found"; return 1
}

register SVC-002 medium SERVICES "A firewall is ACTIVE (not just installed)"
chk_SVC_002() {
  is_live || { DETAIL="live check only"; return 2; }
  if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -q "Status: active" && { DETAIL="ufw active"; return 0; }
  fi
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet firewalld 2>/dev/null && { DETAIL="firewalld active"; return 0; }
  fi
  if command -v iptables >/dev/null 2>&1; then
    local n; n=$(iptables -S 2>/dev/null | grep -c -- '^-A') ; [[ ${n:-0} -gt 0 ]] && { DETAIL="iptables has $n rules"; return 0; }
  fi
  DETAIL="no active firewall detected (or not root)"; return 1
}

register SVC-003 medium SERVICES "fail2ban (or equivalent brute-force blocker) is installed"
chk_SVC_003() {
  _has_pkg_or_unit fail2ban && { DETAIL="fail2ban present"; return 0; }
  _has_pkg_or_unit sshguard && { DETAIL="sshguard present"; return 0; }
  DETAIL="no fail2ban/sshguard"; return 1
}

register SVC-004 medium SERVICES "Automatic security updates are configured"
chk_SVC_004() {
  if [[ -e $(rp /etc/apt/apt.conf.d/20auto-upgrades) ]]; then
    grep -q 'Unattended-Upgrade "1"' "$(rp /etc/apt/apt.conf.d/20auto-upgrades)" && { DETAIL="unattended-upgrades on"; return 0; }
    DETAIL="20auto-upgrades exists but not enabled"; return 1
  fi
  [[ -e $(rp /etc/dnf/automatic.conf) || -e $(rp /etc/yum/yum-cron.conf) ]] && { DETAIL="dnf-automatic/yum-cron config present"; return 0; }
  DETAIL="no auto-update config"; return 1
}

register SVC-005 critical SERVICES "No legacy plain-text services (telnet, rsh, rlogin, tftp, vsftpd/ftp, xinetd)"
chk_SVC_005() {
  local n bad=""
  for n in telnetd in.telnetd rshd rlogind in.rshd in.tftpd tftpd vsftpd xinetd; do
    if is_live; then
      if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet "$n" 2>/dev/null; then bad+="$n "; fi
    else
      [[ -e $(rp /usr/sbin/$n) || -e $(rp /usr/bin/$n) || -e $(rp /etc/xinetd.d/$n) || -e $(rp /etc/$n) ]] && bad+="$n "
    fi
  done
  DETAIL="${bad:+legacy service: $bad}"; DETAIL=${DETAIL:-none}
  [[ -z $bad ]]
}

register SVC-006 medium SERVICES "auditd (system call auditing) is installed"
chk_SVC_006() { _has_pkg_or_unit auditd && { DETAIL="auditd present"; return 0; }; _has_pkg_or_unit audit && return 0; DETAIL="auditd missing"; return 1; }

register SVC-007 low SERVICES "Time sync (chrony / systemd-timesyncd / ntpd) is configured"
chk_SVC_007() {
  local n; for n in chrony chronyd systemd-timesyncd ntp ntpd; do _has_pkg_or_unit "$n" && { DETAIL="found $n"; return 0; }; done
  [[ -e $(rp /etc/chrony.conf) || -e $(rp /etc/chrony/chrony.conf) || -e $(rp /etc/systemd/timesyncd.conf) ]] && { DETAIL="time sync config present"; return 0; }
  DETAIL="no time-sync service found"; return 1
}

register SVC-008 medium SERVICES "No unexpected services listen on all interfaces"
chk_SVC_008() {
  is_live || { DETAIL="live check only"; return 2; }
  command -v ss >/dev/null 2>&1 || return 2
  local allowed=" ${HK_ALLOWED_PORTS:-22} " out=""
  while read -r proto addr; do
    local port=${addr##*:} host=${addr%:*}
    [[ $host == "127.0.0.1" || $host == "[::1]" || $host == "127.0.0.53%lo" || $host == "127.0.0.54" ]] && continue
    [[ $allowed == *" $port "* ]] || out+="$proto/$port "
  done < <(ss -H -tuln 2>/dev/null | awk '{print $1, $5}' | sort -u)
  DETAIL="${out:+unexpected listeners: $out (allowed: $allowed)}"; DETAIL=${DETAIL:-only allowed ports listen}
  [[ -z $out ]]
}
