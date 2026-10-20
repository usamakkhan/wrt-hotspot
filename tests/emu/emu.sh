#!/bin/sh
# Emulated OpenWrt routers in QEMU for testing WrtHotspot on other CPUs.
# Runs on any Linux host (WSL2 works) with qemu-system-mips, qemu-system-arm,
# qemu-efi-aarch64, ssh, curl and python3.
#
#   emu.sh fetch                 download the images
#   emu.sh boot ROUTER           run a router in the foreground (background it)
#   emu.sh setup ROUTER          via the serial console: LAN on QEMU's DHCP, SSH key
#   emu.sh install ROUTER        install wrt-hotspot-full from the release feed,
#                                exactly as the README says
#   emu.sh deploy ROUTER [FILE...]  copy core package files from this checkout
#                                over the installed ones and restart (paths
#                                relative to feed/net/wrt-hotspot/files/;
#                                default: every usr/share/ucode/wrthotspot/*.uc)
#   emu.sh deps ROUTER           test tools (veth, tc, iperf3, FreeRADIUS ...)
#   emu.sh test ROUTER           copy tests/, run unit tests, start the
#                                integration suites detached
#   emu.sh status ROUTER         suite progress and results
#   emu.sh ssh ROUTER [CMD]      shell on the router
#   emu.sh all ROUTER            setup, install, deps and test in one go
#
# Routers: malta (MIPS 24Kc big-endian, OpenWrt 25.12, 128 MB),
#          malta24 (same, OpenWrt 24.10, opkg), armv8 (Cortex-A53, 256 MB),
#          armv7 (Cortex-A15, 256 MB). MEM=... overrides the RAM size.
# Emulation proves the code on these CPUs and with this little RAM; it does
# not test real router hardware (switch, Wi-Fi, flash).

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
E=${EMU_DIR:-$HOME/.cache/wrthotspot-emu}
V25=25.12.6
V24=24.10.8
FEED=${FEED:-https://github.com/usamakkhan/wrt-hotspot/releases/latest/download}
DL=https://downloads.openwrt.org/releases

router() {	# sets N (number), PM (package manager)
	case "$1" in
	malta)   N=1; PM=apk ;;
	malta24) N=2; PM=opkg ;;
	armv8)   N=3; PM=apk ;;
	armv7)   N=4; PM=apk ;;
	*) echo "unknown router '$1' (malta, malta24, armv8, armv7)" >&2; exit 1 ;;
	esac
	SERIAL=450$N
	SSHP=220$N
}

key() {
	[ -f "$E/id_ed25519" ] || { mkdir -p "$E"; ssh-keygen -q -t ed25519 -N '' -C wrthotspot-emu -f "$E/id_ed25519"; }
}

r() {	# r CMD...  run on the router over SSH
	ssh -q -i "$E/id_ed25519" -p "$SSHP" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
		-o ServerAliveInterval=15 -o ConnectTimeout=20 root@127.0.0.1 "$@"
}

cmd=$1; [ $# -gt 0 ] && shift
case "$cmd" in
fetch)
	mkdir -p "$E" && cd "$E" || exit 1
	for f in \
		$V25/targets/malta/be/openwrt-$V25-malta-be-vmlinux-initramfs.elf \
		$V24/targets/malta/be/openwrt-$V24-malta-be-vmlinux-initramfs.elf \
		$V25/targets/armsr/armv8/openwrt-$V25-armsr-armv8-generic-ext4-combined-efi.img.gz \
		$V25/targets/armsr/armv7/openwrt-$V25-armsr-armv7-generic-ext4-combined-efi.img.gz
	do
		n=$(basename "$f" .gz)
		[ -f "$n" ] && continue
		curl -fsSLO "$DL/$f" || { echo "download failed: $f"; exit 1; }
		case "$f" in *.gz) gunzip -f "$(basename "$f")" 2>/dev/null ;; esac
	done
	ls -l "$E"
	;;
boot)
	router "$1"
	NET="-netdev user,id=n0,hostfwd=tcp:127.0.0.1:$SSHP-:22"
	CON="-display none -monitor none -serial tcp:127.0.0.1:$SERIAL,server=on,wait=off"
	case "$1" in
	malta|malta24)
		v=$V25; [ "$1" = malta24 ] && v=$V24
		exec qemu-system-mips -M malta -cpu 24Kc -m "${MEM:-128}" \
			-kernel "$E/openwrt-$v-malta-be-vmlinux-initramfs.elf" \
			$CON $NET -device pcnet,netdev=n0 ;;
	armv8)
		exec qemu-system-aarch64 -M virt -cpu cortex-a53 -smp 2 -m "${MEM:-256}" \
			-bios /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
			-drive file="$E/openwrt-$V25-armsr-armv8-generic-ext4-combined-efi.img",format=raw,if=virtio \
			$CON $NET -device virtio-net-pci,netdev=n0 ;;
	armv7)
		exec qemu-system-arm -M virt,highmem=off -cpu cortex-a15 -smp 2 -m "${MEM:-256}" \
			-bios /usr/share/AAVMF/AAVMF32_CODE.fd \
			-drive file="$E/openwrt-$V25-armsr-armv7-generic-ext4-combined-efi.img",format=raw,if=virtio \
			$CON $NET -device virtio-net-pci,netdev=n0 ;;
	esac
	;;
setup)
	router "$1"; key
	python3 "$HERE/console.py" "$SERIAL" --wait-boot 300 \
		'dmesg -n 1' \
		'uci set network.lan.proto=dhcp; uci -q delete network.lan.ipaddr; uci -q delete network.lan.ip6assign; uci commit network' \
		'service network reload' \
		"echo '$(cat "$E/id_ed25519.pub")' > /etc/dropbear/authorized_keys; chmod 600 /etc/dropbear/authorized_keys" || exit 1
	# Wait for the DHCP lease and SSH.
	for i in $(seq 1 30); do r true 2>/dev/null && { echo "router $1 ready on ssh port $SSHP"; exit 0; }; sleep 2; done
	echo "router $1: no SSH after setup"; exit 1
	;;
install)
	router "$1"
	if [ $PM = apk ]; then
		r sh -s "$FEED" <<'EOF'
U=$1
wget -q -O /etc/apk/keys/wrthotspot.pem $U/wrthotspot.pem || { echo "key download failed"; exit 1; }
grep -q wrt-hotspot /etc/apk/repositories.d/customfeeds.list || echo $U/packages.adb >> /etc/apk/repositories.d/customfeeds.list
apk update >/dev/null 2>&1
s=$(date +%s)
apk add wrt-hotspot-full 2>&1 | tail -1 || exit 1
echo "installed in $(( $(date +%s) - s ))s"
apk list -I 2>/dev/null | grep -o '^[a-z-]*hotspot[a-z-]*-[0-9.]*-r[0-9]*'
EOF
	else
		r sh -s "$FEED" <<'EOF'
U=$1
wget -q -O /tmp/wrthotspot.pub $U/dcedbf2d84a0ef59 && opkg-key add /tmp/wrthotspot.pub || { echo "key failed"; exit 1; }
grep -q wrthotspot /etc/opkg/customfeeds.conf || echo "src/gz wrthotspot $U" >> /etc/opkg/customfeeds.conf
opkg update 2>&1 | grep -iE "wrthotspot|signature" | sort | uniq -c
s=$(date +%s)
opkg install wrt-hotspot-full >/dev/null 2>&1 || exit 1
echo "installed in $(( $(date +%s) - s ))s"
opkg list-installed | grep hotspot
EOF
	fi
	;;
deploy)
	router "$1"; name=$1; shift
	F="$ROOT/feed/net/wrt-hotspot/files"
	[ $# -gt 0 ] || set -- $(cd "$F" && ls usr/share/ucode/wrthotspot/*.uc)
	(cd "$F" && tar czf - "$@") | r 'tar xzf - -C / && /etc/init.d/wrthotspot restart' || exit 1
	echo "deployed $# file(s) to $name"
	;;
deps)
	router "$1"
	r sh -s <<'EOF'
P="dnsmasq-full ip-full kmod-veth curl tc-full kmod-sched kmod-sched-core kmod-ifb iperf3 conntrack
   freeradius3 freeradius3-mod-files freeradius3-mod-pap freeradius3-mod-chap freeradius3-mod-detail freeradius3-utils
   libopenssl-legacy"	# radiusd on 24.10 crash-loops without OpenSSL's legacy provider
if command -v apk >/dev/null; then
	apk del dnsmasq >/dev/null 2>&1; apk add $P 2>&1 | tail -1
else
	opkg remove dnsmasq >/dev/null 2>&1; opkg install $P 2>&1 | tail -1
fi
/etc/init.d/radiusd disable 2>/dev/null; /etc/init.d/radiusd stop 2>/dev/null
/etc/init.d/dnsmasq enable; /etc/init.d/dnsmasq restart
free -m | sed -n 2p; df -h / | sed -n 2p
EOF
	;;
test)
	router "$1"
	(cd "$ROOT" && tar czf - tests feed) | r 'rm -rf /tmp/hs && mkdir -p /tmp/hs && tar xzf - -C /tmp/hs' || exit 1
	r 'sh /tmp/hs/tests/run-unit.sh 2>&1 | grep -E "passed|PASSED|FAIL|nft syntax"'
	r sh -s <<'EOF'
cat > /tmp/hs/suites.sh <<'EOS'
cd /tmp/hs
run() {
	echo "=== $* $(date +%T)"
	s=$(date +%s)
	case "$1" in
	*.uc) ucode tests/integration/"$@" 2>&1 ;;
	*) sh tests/integration/"$@" 2>&1 ;;
	esac
	echo "=== $1 rc=$? $(( $(date +%s) - s ))s, $(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo) MB available"
}
# Initramfs images keep the whole root (packages + ~30 MB of test tools) in
# RAM, where a flash router keeps it on flash: the safe-mode reserve would
# leave room for a single session. The suites run in max mode instead
# (netns-test.sh applies it to the config it installs; cleanup restores).
export HS_CAPACITY_MODE=max
run netns-test.sh keep
run regression-test.sh
run capacity-test.sh
run panel-api-test.sh
run rosapi-test.uc
run netns-test.sh cleanup >/dev/null
echo "=== ALL DONE"
EOS
(sh /tmp/hs/suites.sh > /tmp/hs/suites.log 2>&1 < /dev/null &)
echo "integration suites started; follow with: emu.sh status"
EOF
	;;
status)
	router "$1"
	r "grep -E '^===|FAIL|RESULT' /tmp/hs/suites.log"
	;;
ssh)
	router "$1"; shift
	r "$@"
	;;
all)
	for s in setup install deps test; do "$0" $s "$1" || exit 1; done
	;;
*)
	sed -n '2,27p' "$0"; exit 1 ;;
esac
