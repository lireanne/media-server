## /etc/network/iptables-rules.sh

#!/bin/bash

HOST_IP=REPLACE_ME
JELLYFIN_LXC=REPLACE_ME
RR_LXC=REPLACE_ME

case "$1" in
  up)   CMD="-A" ;;
  down) CMD="-D" ;;
  *) echo "Usage: $0 up|down"; exit 1 ;;
esac

# NAT for LXC subnet
iptables -t nat $CMD POSTROUTING -s '192.168.100.0/24' -o wlo1 -j MASQUERADE

# Jellyfin
iptables -t nat $CMD PREROUTING -d $HOST_IP -p tcp --dport 8096 -j DNAT --to-destination $JELLYFIN_LXC:8096

# Sonarr
iptables -t nat $CMD PREROUTING -d $HOST_IP -p tcp --dport 8989 -j DNAT --to-destination $ARR_LXC:8989

# Radarr
iptables -t nat $CMD PREROUTING -d $HOST_IP -p tcp --dport 7878 -j DNAT --to-destination $ARR_LXC:7878

# qBittorrent
iptables -t nat $CMD PREROUTING -d $HOST_IP -p tcp --dport 8085 -j DNAT --to-destination $ARR_LXC:8085

