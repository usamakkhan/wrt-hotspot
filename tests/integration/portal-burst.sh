#!/bin/sh
# Burst probe: N clients (from traffic-test.sh's namespaces hsm1..N, kept with
# SETUP_ONLY=1 traffic-test.sh N) hit the portal at once; samples portal
# process count and memory.
N=${1:-200}
URL=${2:-http://10.98.0.2/x}
pid=$(pgrep -f 'uhttpd -f -D -p 0.0.0.0:8002' | head -1)
echo "portal pid $pid, hotspotd pid $(pgrep -f hotspotd), avail $(awk '/MemAvailable/{print $2}' /proc/meminfo) KiB"
for i in $(seq 1 "$N"); do
	ip netns exec "hsm$i" curl -s -m 30 -o /dev/null -w '%{http_code}\n' "$URL" > "/tmp/hsm/burst.$i" &
done
peak=0; low=999999	# portal processes (master + workers)
for s in $(seq 1 10); do
	c=$(pgrep -f "uhttpd -f -D -p 0.0.0.0:8002" | wc -l)
	m=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
	[ "$c" -gt "$peak" ] && peak=$c
	[ "$m" -lt "$low" ] && low=$m
	sleep 1	# busybox sleep: whole seconds
done
wait
echo "peak portal children $peak, lowest avail $low KiB"
cat /tmp/hsm/burst.* | sort | uniq -c
echo "hotspotd pid now $(pgrep -f hotspotd), portal pid now $(pgrep -f 'uhttpd -f -D -p 0.0.0.0:8002' | head -1)"
