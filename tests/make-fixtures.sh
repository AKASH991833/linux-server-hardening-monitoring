#!/usr/bin/env bash
# Build two fake root filesystems: "insecure" (a typical lazy default server) and "hardened".
# usage: tests/make-fixtures.sh DEST_DIR
set -euo pipefail
D=${1:?usage: make-fixtures.sh DEST}
rm -rf "$D"; mkdir -p "$D"

common() { # $1 = root
  local r=$1
  mkdir -p "$r"/etc/{ssh/sshd_config.d,sudoers.d,cron.d,security,apt/apt.conf.d,sysctl.d,pam.d} "$r"/home/{alice,bob} "$r"/tmp "$r"/var/log "$r"/usr/bin "$r"/usr/sbin "$r"/bin "$r"/root/.ssh
  cat > "$r/etc/passwd" <<P
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
alice:x:1000:1000:Alice:/home/alice:/bin/bash
bob:x:1001:1001:Bob:/home/bob:/bin/bash
P
  printf 'root:$6$x:19000:0:99999:7:::\nalice:$6$y:19000:0:99999:7:::\nbob:$6$z:19000:0:99999:7:::\n' > "$r/etc/shadow"
  echo "Include /etc/ssh/sshd_config.d/*.conf" > "$r/etc/ssh/sshd_config"
  : > "$r/etc/hosts"; : > "$r/etc/fstab"; : > "$r/etc/group"
  printf 'root ALL=(ALL:ALL) ALL\n' > "$r/etc/sudoers"
}

# ---------- insecure ----------
I="$D/insecure"; common "$I"
cat >> "$I/etc/ssh/sshd_config" <<'S'
PermitRootLogin yes
PasswordAuthentication yes
PermitEmptyPasswords yes
X11Forwarding yes
MaxAuthTries 10
LoginGraceTime 2m
Ciphers aes128-cbc,3des-cbc,aes256-ctr
Match User backup
    PasswordAuthentication no
S
chmod 644 "$I/etc/ssh/sshd_config"
printf 'toor:x:0:0:evil:/root:/bin/bash\nmysql:x:105:105::/var/lib/mysql:/bin/bash\n' >> "$I/etc/passwd"
printf 'toor::19000:0:99999:7:::\n' >> "$I/etc/shadow"
chmod 666 "$I/etc/shadow" "$I/etc/passwd"
printf 'PASS_MAX_DAYS 99999\nPASS_MIN_DAYS 0\nUMASK 022\n' > "$I/etc/login.defs"
echo 'deploy ALL=(ALL) NOPASSWD: ALL' > "$I/etc/sudoers.d/deploy"
printf 'minlen = 6\n' > "$I/etc/security/pwquality.conf"
printf 'net.ipv4.ip_forward = 1\n' > "$I/etc/sysctl.conf"
touch "$I/usr/bin/telnetd" "$I/usr/sbin/vsftpd"; chmod 666 "$I/usr/bin/telnetd"
echo "user bob" > "$I/home/bob/.netrc"
chmod 777 "$I/home/alice"; chmod 755 "$I/home/bob"
touch "$I/tmp/rootshell"; chmod 4755 "$I/tmp/rootshell"; chmod 755 "$I/tmp"
chmod 666 "$I/etc/crontab" 2>/dev/null || { : > "$I/etc/crontab"; chmod 666 "$I/etc/crontab"; }

# ---------- hardened ----------
H="$D/hardened"; common "$H"
cat > "$H/etc/ssh/sshd_config.d/10-secure.conf" <<'S'
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
Banner /etc/issue.net
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes256-ctr
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
S
chmod 600 "$H/etc/ssh/sshd_config"; echo banner > "$H/etc/issue.net"
chmod 644 "$H/etc/passwd"; chmod 640 "$H/etc/shadow"
printf 'PASS_MAX_DAYS 90\nPASS_MIN_DAYS 1\nUMASK 027\n' > "$H/etc/login.defs"
printf 'minlen = 14\n' > "$H/etc/security/pwquality.conf"
cat > "$H/etc/sysctl.d/90-secure.conf" <<'S'
net.ipv4.ip_forward = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
kernel.randomize_va_space = 2
fs.suid_dumpable = 0
kernel.dmesg_restrict = 1
S
mkdir -p "$H/etc/fail2ban" "$H/etc/ufw" "$H/etc/audit" "$H/etc/chrony"
echo 'APT::Periodic::Unattended-Upgrade "1";' > "$H/etc/apt/apt.conf.d/20auto-upgrades"
touch "$H/usr/sbin/ufw" "$H/usr/sbin/auditd" "$H/etc/chrony/chrony.conf"
chmod 700 "$H/home/alice" "$H/home/bob"; chmod 1777 "$H/tmp"; chmod 600 "$H/etc/crontab" 2>/dev/null || { : > "$H/etc/crontab"; chmod 600 "$H/etc/crontab"; }
mkdir -p "$H/home/alice/.ssh"; echo "ssh-ed25519 AAAA... alice@laptop" > "$H/home/alice/.ssh/authorized_keys"
echo "fixtures ready in $D"
