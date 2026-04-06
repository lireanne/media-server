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

### 2.1. Wi‑Fi Configuration (wlo1)

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

### 2.2. Proxmox Bridge and NAT (Internal Network)

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

	
# NAT and port forwarding rules (see /etc/network/iptables-rules.sh)
    post-up echo 1 > /proc/sys/net/ipv4/ip_forward
    post-up /etc/network/iptables-rules.sh up
    post-down /etc/network/iptables-rules.sh down

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

From any device on the main LAN (`192.168.18.0/24`), **Jellyfin** can be accessed at http://192.168.18.35:8096.

- Those host ports are forwarded via DNAT to Jellyfin LXC: `192.168.100.2:8096`.
- (These DNAT rules are already included in the `vmbr0` section above.)

## 3. LXC Containers

Create the following LXC containers:

- `jellyfin` (LXC 101, media server)
- `qbit-arr` (LXC 100, Debian, runs Docker for qBittorrent + \*arr stack)

All are on `vmbr0` with static IPs:

- `jellyfin`: `192.168.100.2/24`
- `qbit-arr`: `192.168.100.100/24`
- Gateway for all: `192.168.100.1` (vmbr0)

Both LXCs have ironwolf4 bind-mounted:
- Host: `/mnt/ironwolf4` → LXC: `/mnt/media` (configured via `mp0` in LXC config)

## 4. External HDD Setup

A 4TB Seagate IronWolf HDD in an external enclosure is used for all media storage.

### 4.1. Partition and Format

```bash
# Create GPT partition table and single partition
sudo parted /dev/sdb --script mklabel gpt mkpart primary 0% 100%

# Format as Btrfs (chosen for checksumming, snapshots, future RAID expansion)
sudo apt install btrfs-progs
sudo mkfs.btrfs -f -L ironwolf4 /dev/sdb1
```

### 4.2. Mount and fstab

```bash
sudo mkdir -p /mnt/ironwolf4
sudo mount /dev/sdb1 /mnt/ironwolf4
```

Get UUID and add to `/etc/fstab`:

```bash
sudo blkid /dev/sdb1
```

Add to `/etc/fstab`:

```
UUID=<your-uuid>  /mnt/ironwolf4  btrfs   defaults,nofail 0       0
```

Then reload:

```bash
systemctl daemon-reload
```

### 4.3. Directory Structure

```
/mnt/ironwolf4/
├── downloads/
│     ├── tv/       ← qBittorrent tv-sonarr category
│     ├── movies/   ← qBittorrent radarr category
│     └── music/    ← qBittorrent lidarr category
├── movies/
├── music/
├── tvseries/
└── qbitt/
      └── config/   ← qBittorrent app config
```

### 4.4. Permissions

Since LXC containers are unprivileged, the host UID maps as `container UID + 100000`. For `sona` (UID 1000 inside LXC):

```bash
# Set from host as actual root
chown -R 101000:101000 /mnt/ironwolf4/
```

**Note:** Device name (`/dev/sdb` vs `/dev/sdc`) may change on reconnect. fstab uses UUID so auto-mount is unaffected. If the mount goes stale:

```bash
umount -l /mnt/ironwolf4
mount /mnt/ironwolf4
```

---

## 5. Jellyfin LXC Container

### 5.1. Create the LXC

In Proxmox UI:

- Template: `turnkey-mediaserver` (unprivileged)
- Resources: `1` core, `512 MiB` RAM, `8 GiB` disk
- Network:
  - Bridge: `vmbr0`
  - IPv4: static
  - IPv4/CIDR: `192.168.100.2/24`
  - IPv4 Gateway: `192.168.100.1`

See `lxc-config` for final .conf file.

### 5.2. Mount ironwolf4 into Jellyfin LXC

```bash
sudo pct set 101 -mp0 /mnt/ironwolf4,mp=/mnt/media
```

Jellyfin will use `/mnt/media` as its library path.

## 6. qbit-arr LXC Container (Docker Host)

This container runs Docker and hosts:

- qBittorrent
- Sonarr
- Radarr
- Lidarr
- Prowlarr
- Bazarr
- (Optionally) Gluetun VPN

### 6.1. Create the LXC

In Proxmox UI:

- Template: `debian` (unprivileged)
- Resources: `2` cores, `1024 MiB` RAM
- Disk: `20 GiB` (app configs only — media lives on ironwolf4)
- Network:
  - Bridge: `vmbr0`
  - IPv4: static
  - IPv4/CIDR: `192.168.100.100/24`
  - IPv4 Gateway: `192.168.100.1`

See `lxc-config` for final .conf file.

### 6.2. Mount ironwolf4 into qbit-arr LXC

```bash
sudo pct set 100 -mp0 /mnt/ironwolf4,mp=/mnt/media
```

Now `/mnt/ironwolf4` on the host is visible as `/mnt/media` inside `qbit-arr`.

### 6.3. Permissions

```bash
# From host as root — sets ownership for sona (UID 1000 in LXC = 101000 on host)
chown -R 101000:101000 /mnt/ironwolf4/
```

**Note:** In an unprivileged LXC, Docker containers cannot `chown` bind-mounted directories regardless of `privileged: true`. Pre-setting ownership from the host is required for linuxserver.io images to work correctly.

## 7. Docker Stack (qBittorrent + \*arr stack)

All commands below are run inside the `qbit-arr` LXC.

### 7.1. Install Docker and Docker Compose

In `qbit-arr` LXC, install `docker` and `docker-compose`, then bring the stack up:

```bash
docker compose up -d
```

**TODO: set up docker with Gluetun/VPN.**

### 7.2. docker-compose.yml

See `docker-compose.yml` in this repo. All containers share a unified `/data` mount pointing to `/mnt/media` (ironwolf4), enabling hardlinks between downloads and media folders — no duplicate disk usage.

### 7.3. Volume Mount Path Reference

```
HDD (Btrfs /dev/sdb1)
    └── mounted at HOST: /mnt/ironwolf4/
          └── bind mount → LXC 100: /mnt/media/
                └── Docker volume → containers: /data/
                      ├── /data/downloads/tv/      ← qBittorrent saves here (tv-sonarr category)
                      ├── /data/downloads/movies/  ← qBittorrent saves here (radarr category)
                      ├── /data/downloads/music/   ← qBittorrent saves here (lidarr category)
                      ├── /data/tvseries/          ← Sonarr media library
                      ├── /data/movies/            ← Radarr media library
                      └── /data/music/             ← Lidarr media library
```


## 8. UI Wiring: Connecting Everything

### 8.1 Connect Sonarr/Radarr/Lidarr to qBittorrent

In each app go to **Settings → Download Clients → Add → qBittorrent**:

- Host: `qbittorrent` (Docker container name)
- Port: `8085`
- Category: `tv-sonarr` / `radarr` / `lidarr`

Root folders:
- Sonarr: `/data/tvseries`
- Radarr: `/data/movies`
- Lidarr: `/data/music`

Import Mode: **Hardlink** (zero extra disk space, original stays for seeding)

Completed Download Handling: **Remove Completed** enabled (Sonarr/Radarr remove torrent from qBittorrent after import)

### 8.2 Connect Prowlarr to Sonarr/Radarr/Lidarr

In **Prowlarr**:

- Add indexers as needed.
- Under **Applications**, add Sonarr, Radarr, Lidarr
  - URL: use container name as host (e.g. `http://sonarr:8989`)
  - API keys from each app.

Prowlarr will push indexer results to the arr apps, which send torrents to qBittorrent.

## 9. Final Notes / Maintenance

- **Media library refresh**: Jellyfin → rescan libraries after new content arrives.
- **Disk health**: run `smartctl -a /dev/sdb` periodically to check ironwolf4 SMART data.
- **Backups**:
  - Back up `/home/docker` (app configs and databases)
  - Back up `/etc/pve/lxc/*.conf` and `/etc/network/interfaces`
  - ironwolf4 has no redundancy — consider offsite backup for important media.

Once all pieces are up:

- LAN clients reach Jellyfin at `http://192.168.2.35:8096`
- Automation pipeline:
  - Prowlarr → Sonarr/Radarr/Lidarr → qBittorrent → `/data/downloads/{tv,movies,music}` → hardlinked to `/data/{tvseries,movies,music}` → Jellyfin libraries.
