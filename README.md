# Home Media Server: Proxmox + Jellyfin + \*arr Stack

This document describes how to create a POC home media setup running on:

- **Host OS**: Proxmox VE (on Debian 12)
- **Host name**: `my-machine` (Beelink Mini S12 Pro Intel 12th N100)
- **WAN/LAN**: Wi‑Fi connection to ISP router (`my-wifi`)
- **Internal virtual network**: `192.168.100.0/24` (LXC + Docker)

## 1. Host Overview

- **OS**: Proxmox VE (Debian 12)
- **Kernel**: `6.8.12-8-pve`
- **Hostname**: `my-machine`
- **Router SSID**: `my-wifi`
- **Router LAN IP**: `192.168.2.1`
- **Host IP on LAN (Wi‑Fi)**: `192.168.2.35` (static)

In lieu of optimal ethernet setup, the host connects to the home router via Wi‑Fi (`wlo1`) and acts as a router/NAT gateway for an internal Proxmox network `192.168.100.0/24` served by the bridge interface `vmbr0`.

## 2. Networking Configuration

### 2.1. Disable IPv6 (Optional, for ISPs without IPv6)

For those whose ISP does not support IPv6 and you are seeing connectivity issues (e.g. `ping` preferring IPv6), disable IPv6 at the kernel level:

Edit `/etc/default/grub`:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet ipv6.disable=1"
GRUB_CMDLINE_LINUX="ipv6.disable=1"
```

Apply:

```
sudo update-grub
sudo reboot
```

Then, test IPv6 connectivity (or lack thereof) with an external tool like `test-ipv6.com`.

---

### 2.2. Wi‑Fi Configuration (wlo1)

The host uses `wlo1` as its primary uplink interface. **However, Beelink S12 Pro runs Intel AX101 wifi driver which is known to have compatibility issues with certain kernels such as the Proxmox/Debian ones used here.** Disabling Wifi 6 (802.11ax) forces the driver to negotiate connections using the older, more stable 802.11ac (Wi-Fi 5) or 802.11n standards.

1.  **Configure iwlwifi for better stability (AX101)**

    Create `/etc/modprobe.d/iwlwifi.conf`:

    ```
    echo "options iwlwifi disable_11ax=1" | sudo tee /etc/modprobe.d/iwlwifi.conf
    ```

    Reload driver:

    ```
    sudo modprobe -r iwlwifi
    sudo modprobe iwlwifi
    ```

    Bring up interface:

    ```
    sudo ifup wlo1
    ```

2.  **Configure WPA supplicant**

    Generate and store Wi‑Fi credentials:

    ```
    sudo wpa_passphrase "Your_SSID" "Your_Password" | sudo tee /etc/wpa_supplicant/wpa_supplicant.conf
    ```

3.  **Tell networking to use wpa_supplicant for wlo1**

    Edit `/etc/network/interfaces` (snippet):

    ```
    ...
    iface wlo1 inet dhcp
        wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
    ```

---

### 2.3. Proxmox Bridge and NAT (Internal Network)

Goal:

- Create internal subnet `192.168.100.0/24` on `vmbr0` for LXC containers.
- Route traffic from `192.168.100.0/24` to the internet via `wlo1` using NAT.
- Disable IPv6 on `vmbr0`.

Final `/etc/network/interfaces` (core parts):

```
source /etc/network/interfaces.d/*

auto lo
iface lo inet loopback

iface enp1s0 inet manual
# bring up interface automatically at boot
auto vmbr0
iface vmbr0 inet static
	address 192.168.100.1/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0

# NAT interface routing
# forward traffic from LXC subnet (192.168.100.0/24) -> wlo1/wifi -> internet
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up iptables -t nat -A POSTROUTING -s '192.168.100.0/24' -o wlo1 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '192.168.100.0/24' -o wlo1 -j MASQUERADE

# Jellyfin: forward traffic from host(192.168.2.35):8096 → LXC 192.168.100.2:8096
    post-up   iptables -t nat -A PREROUTING -d 192.168.2.35 -p tcp --dport 8096 -j DNAT --to-destination 192.168.100.2:8096
    post-down iptables -t nat -D PREROUTING -d 192.168.2.35 -p tcp --dport 8096 -j DNAT --to-destination 192.168.100.2:8096

# disable ipv6 (ISP doesn't support)
    post-up echo 0 > /proc/sys/net/ipv6/conf/vmbr0/disable_ipv6 || true

iface wlo1 inet dhcp
    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
```

After editing:

```
sudo systemctl restart networking

# or

sudo ifdown vmbr0 && sudo ifup vmbr0
```

Result:

- `vmbr0`: `192.168.100.1/24`, default gateway for internal containers.
- Containers get static IPs in `192.168.100.0/24`.
- Outbound traffic from containers is NATed through `wlo1`.

From any device on the main LAN (`192.168.2.0/24`), **Jellyfin** can be accessed at http://192.168.2.35:8096.

- Those host ports are forwarded via DNAT to Jellyfin LXC: `192.168.100.2:8096`.
- (These DNAT rules are already included in the `vmbr0` section above.)

## 3. LXC Containers

Create the following LXC containers:

- `jellyfin` (media server template)
- `qbit-arr` (Debian, runs Docker for qBittorrent + \*arr stack)

All are on `vmbr0` with static IPs:

- `plex`: `192.168.100.3/24`
- `qbit-arr`: `192.168.100.100/24`
- Gateway for all: `192.168.100.1` (vmbr0)

## 4. Jellyfin LXC Container

### 4.1. Create the LXC

In Proxmox UI:

- Template: `turnkey-mediaserver` (unprivileged)
- Resources: `1` core, `512 MiB` RAM, `8 GiB` disk
- Network:
  - Bridge: `vmbr0`
  - IPv4: static
  - IPv4/CIDR: `192.168.100.2/24`
  - IPv4 Gateway: `192.168.100.1`

See `lxc-config` for final .conf file.

### 4.2. Mount Host Media Dir into Jellyfin LXC

**TODO: set up external HDD / NAS. For POC, use host machine memory.**

On the host:

```
# Ensure media directory exists on host

sudo mkdir -p /mnt/media

# Attach to LXC (replace 101 with your CTID)

sudo pct set 101 -mp0 /mnt/media,mp=/mnt/media
```

Jellyfin will use `/mnt/media` as its library path.

## 5. qbit-arr LXC Container (Docker Host)

This container runs Docker and hosts:

- qBittorrent
- Sonarr
- Radarr
- Lidarr
- Prowlarr
- Bazarr
- (Optionally) Gluetun VPN

### 5.1. Create the LXC

In Proxmox UI:

- Template: `debian` (unprivileged)
- Resources: `2` cores, `1024 MiB` RAM
- Disk: `400 GiB` (for media + Docker configs) (TODO: use external HDD)
- Network:
  - Bridge: `vmbr0`
  - IPv4: static
  - IPv4/CIDR: `192.168.100.100/24`
  - IPv4 Gateway: `192.168.100.1`

See `lxc-config` for final .conf file.

### 5.2. Mount Media from Host

The arr\* stack also requires access to media files.

On the host:

```
sudo mkdir -p /mnt/media

# Attach to qbit-arr LXC
sudo pct set 100 -mp0 /mnt/media,mp=/mnt/media
```

Now `/mnt/media` is visible inside `qbit-arr`.

### 5.3. Permissions for Media Directory

Grant media directory to arr PVRs in `qbit-arr` LXC:

```
# Create user to run Docker apps
adduser sona

id sona
# Expect: uid=1000(sona) gid=1000(sona) ...
```

Assign ownership inside LXC:

```
sudo chown -R 1000:1000 /mnt/media
```

On the host, match the mapped UID (LXC unprivileged mapping = UID + 100000)

```
sudo chown 101000:101000 /mnt/media  # host UID = container UID + 100000
sudo chmod 755 /mnt/media
```

This ensures Docker containers (running as UID 1000 in LXC) can write to `/mnt/media`.

## 6. Docker Stack (qBittorrent + \*arr stack)

All commands below are run inside the `qbit-arr` LXC as `sona` (or root, but using UID 1000 for volumes).

### 6.1. Install Docker and Docker Compose

In `qbit-arr` LXC, first install `docker` and `docker-compose`.

Bring the stack up:

```
docker compose [-f <docker-compose file name>] up -d
```

**TODO: set up docker with Glutun/VPN.**

### 6.2. qBittorrent Web UI Initial Password

After starting qBittorrent, look in logs to get the intiial password.

```
docker logs -f qbittorrent

# Expected:
# ******** Information ********
# To control qBittorrent, access the WebUI at: http://localhost:8085
# The WebUI administrator username is: admin
# The WebUI administrator password was not set. A temporary password is provided for this session: ...
```

Then, access WebUI at [http://localhost:8085](http://localhost:8085) to change password.

## 7. UI Wiring: Connecting Everything

### 7.1 Connect Sonarr/Radarr to qBittorrent

In **Sonarr** and **Radarr**, go to **Download Clients** → **Add** → **qBittorrent** and fill in page.

- Host = LXC IP, port = docker port
- Ensure that:
  - `Downloads` folder in qBittorrent (`/downloads`) corresponds to the same path that Sonarr/Radarr see (`/downloads`).
  - Sonarr/Radarr media folders:
    - `/tv` → mapped to `/mnt/media/tvseries`
    - `/movies` → mapped to `/mnt/media/movies`

### 7.2 Connect Prowlarr to Sonarr/Radarr

In **Prowlarr**:

- Add indexers as needed.
- Under _Applications_, add Sonarr and Radarr
  - URL: use the Sonarr/Radarr endpoints, or via whatever reverse proxy / port mapping you use.
  - API keys from Sonarr/Radarr.

Prowlarr will push indexer results to Sonarr/Radarr, which then send torrents to qBittorrent.

## 8. Final Notes / Maintenance

- **Media library refresh**:
  - Plex: run a library scan after new content arrives.
  - Jellyfin: rescan libraries as needed.
- **Backups**:
  - Back up `/home/docker` (configs, databases).
  - Consider backing up `/etc/pve/lxc/*.conf` and `/etc/network/interfaces`.

Once all pieces are up:

- LAN clients reach Jellyfin media server at http://192.168.2.35:8096`
- Automation pipeline:
  - Prowlarr → Sonarr/Radarr/Lidarr → qBittorrent → downloads go to `/mnt/media` → Jellyfin libraries.
