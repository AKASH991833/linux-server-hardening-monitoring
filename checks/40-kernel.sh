# shellcheck shell=bash
# Kernel / network parameters (sysctl). Live: asks the kernel. Offline: reads sysctl.conf + sysctl.d.

SYSCTL_DROPIN() { rp /etc/sysctl.d/99-hk-hardening.conf; }

_sysctl_expect() { # key expected
  local v; v=$(sysctl_get "$1")
  [[ -n $v ]] || { DETAIL="$1 not set/readable"; return 1; }
  DETAIL="$1 = $v (want $2)"
  [[ $v == "$2" ]]
}
_sysctl_fix() { fx_set_kv "$(SYSCTL_DROPIN)" "$1" "$2" " = "; }

register NET-001 high KERNEL "IP forwarding is off (unless this host is a router)"
chk_NET_001() { _sysctl_expect net.ipv4.ip_forward 0; }
fix_NET_001() { _sysctl_fix net.ipv4.ip_forward 0; }

register NET-002 medium KERNEL "SYN cookies enabled (SYN-flood protection)"
chk_NET_002() { _sysctl_expect net.ipv4.tcp_syncookies 1; }
fix_NET_002() { _sysctl_fix net.ipv4.tcp_syncookies 1; }

register NET-003 medium KERNEL "ICMP redirects are not accepted"
chk_NET_003() { _sysctl_expect net.ipv4.conf.all.accept_redirects 0; }
fix_NET_003() { _sysctl_fix net.ipv4.conf.all.accept_redirects 0; }

register NET-004 medium KERNEL "Source-routed packets are not accepted"
chk_NET_004() { _sysctl_expect net.ipv4.conf.all.accept_source_route 0; }
fix_NET_004() { _sysctl_fix net.ipv4.conf.all.accept_source_route 0; }

register NET-005 medium KERNEL "Reverse-path filtering (anti IP spoofing) is on"
chk_NET_005() {
  local v; v=$(sysctl_get net.ipv4.conf.all.rp_filter); DETAIL="rp_filter = ${v:-unset}"
  [[ $v == 1 || $v == 2 ]]
}
fix_NET_005() { _sysctl_fix net.ipv4.conf.all.rp_filter 1; }

register NET-006 medium KERNEL "Martian packets are logged"
chk_NET_006() { _sysctl_expect net.ipv4.conf.all.log_martians 1; }
fix_NET_006() { _sysctl_fix net.ipv4.conf.all.log_martians 1; }

register KRN-001 high KERNEL "ASLR is fully enabled (randomize_va_space=2)"
chk_KRN_001() { _sysctl_expect kernel.randomize_va_space 2; }
fix_KRN_001() { _sysctl_fix kernel.randomize_va_space 2; }

register KRN-002 medium KERNEL "Core dumps of SUID programs are disabled"
chk_KRN_002() { _sysctl_expect fs.suid_dumpable 0; }
fix_KRN_002() { _sysctl_fix fs.suid_dumpable 0; }

register KRN-003 low KERNEL "dmesg is restricted to root"
chk_KRN_003() { _sysctl_expect kernel.dmesg_restrict 1; }
fix_KRN_003() { _sysctl_fix kernel.dmesg_restrict 1; }

post_kernel() { is_live && fx_run sysctl --system; return 0; }
