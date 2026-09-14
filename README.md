# Jellyfin Manager

A simple Bash script to install and manage [Jellyfin](https://jellyfin.org/) with Docker.

## Features

- Docker installation
- Jellyfin installation and updates
- Start / Stop / Restart
- Status and logs
- External USB media storage
- UUID-based media mounting
- Hardware acceleration with real auto-detection (by GPU vendor ID, not just device presence):
  - Intel Quick Sync (QSV)
  - AMD VA-API
  - NVIDIA NVENC / NVDEC
- Hardware acceleration diagnostics (permissions, stuck ffmpeg transcodes, VAAPI/QSV log errors)
- Auto-Sleep: pauses Jellyfin when nobody is watching anything, and wakes it up automatically on the next connection
- Backup and restore
- Simple terminal menu

## Requirements

- Linux with `systemd` and `apt` (Debian/Ubuntu or derivatives)
- `sudo` access
- Internet connection for the initial Docker/dependency install

The script installs whatever it's missing on its own: `docker`, `docker-compose-plugin`, `git`, and (only if you enable Auto-Sleep) `socat`.

## Installation

```bash
git clone https://github.com/miqcasrag/jellyfin-manager.git
cd jellyfin-manager
chmod +x jellyfin-manager.sh
./jellyfin-manager.sh
```

Running it with no arguments opens the interactive menu. The first time, pick **Install** — this:

- Installs Docker if it isn't already present.
- Creates `jellyfin/docker-compose.yml` and `jellyfin/.env` next to the script.
- Auto-detects the available GPU (Intel/AMD/NVIDIA) and configures hardware acceleration for you.
- Leaves the container running at `http://<your-ip>:8096`.

## Menu usage

Run `./jellyfin-manager.sh` with no arguments. From the main menu you can start/stop/restart the server, view logs, back up, update the image, and enter **Configuration**.

### Configuration

| Option | What it does |
|---|---|
| 1. Media Storage | Lists available partitions (with UUID, label, and filesystem) and sets up a persistent mount in `/etc/fstab`. |
| 2. Hardware Acceleration | Detects and configures QSV / VA-API / NVIDIA, or does it automatically via "Auto-detect". |
| 3. Hardware Acceleration Diagnostics | Checks `/dev/dri` permissions inside the container, active ffmpeg processes, and recent VAAPI/QSV errors in the logs. |
| 4. Auto-Sleep | Enables/disables and shows the status of the low-power mode (see below). |

## Command-line usage

```bash
./jellyfin-manager.sh install              # initial installation
./jellyfin-manager.sh start|stop|restart   # container control
./jellyfin-manager.sh status               # status + docker compose ps table
./jellyfin-manager.sh logs                 # live logs
./jellyfin-manager.sh backup               # configuration backup
./jellyfin-manager.sh update               # updates the Jellyfin image
./jellyfin-manager.sh uninstall            # uninstalls

./jellyfin-manager.sh config               # configuration menu
./jellyfin-manager.sh media                # configure media storage
./jellyfin-manager.sh hardware             # configure hardware acceleration
./jellyfin-manager.sh diagnose             # hardware acceleration diagnostics

./jellyfin-manager.sh autosleep            # enable Auto-Sleep
./jellyfin-manager.sh autosleep-status     # view Auto-Sleep status
./jellyfin-manager.sh autosleep-disable    # disable Auto-Sleep
```

## Hardware acceleration

Detection reads the device's actual **PCI vendor ID** (`/sys/class/drm/renderDXXX/device/vendor`), not just whether `/dev/dri` exists:

- `0x8086` → Intel → Quick Sync (QSV)
- `0x1002` / `0x1022` → AMD → VA-API
- NVIDIA is detected separately via `nvidia-smi`

When configuring QSV/VA-API, the script automatically works out the host's `render`/`video` group GID and adds it to the container (`group_add`) — without this, Jellyfin has no real permission over `/dev/dri` and silently falls back to software transcoding.

**Important:** passing the device through isn't enough on its own. You still need to go into Jellyfin → Dashboard → Playback → Hardware acceleration, select the method, enable hardware decoding/encoding, and disable both "low power" options.

## Auto-Sleep (scale to zero)

Pauses the Jellyfin container when nobody is actively watching anything, and wakes it up automatically on the next connection — no need to start it manually.

### How it works

- Jellyfin's public port (8096) gets taken over by a lightweight TCP proxy (`socat`). Jellyfin itself is remapped to `127.0.0.1:8097`, reachable only internally.
- **On wake:** if the container is paused (the normal case), it's resumed with `docker unpause` — near-instant. Only if it's fully stopped (e.g. after a host reboot) does it do a full cold start with an active health check.
- **On sleep:** a `systemd timer` runs every 5 minutes and asks Jellyfin's own API (`/Sessions`) whether anything is actively playing — not raw network traffic, so a browser tab left open with nothing playing doesn't count as activity. It only pauses (`docker pause`) the container after `N` minutes (configurable) with no active playback session, and never while a scheduled task is running (library scan, etc.).
- There's a 5-minute grace period right after waking up, so it doesn't get paused again before you've had a chance to hit play.

### Enabling it

You need a **Jellyfin API key** (Dashboard → Advanced → API Keys → create one) so the script can check for active playback. Without it, the container will never be auto-paused, to be safe.

```bash
./jellyfin-manager.sh autosleep
```

This will ask for the API key and the idle timeout (30 min by default), install `socat` if missing, remap the port in `docker-compose.yml`, and enable two `systemd` units:

- `jellyfin-wake-proxy.service` — the proxy that wakes the container.
- `jellyfin-idle-watch.timer` / `.service` — the idle watcher.

### Status and disabling

```bash
./jellyfin-manager.sh autosleep-status
./jellyfin-manager.sh autosleep-disable
```

In the main menu, the server status shows `◐ SLEEPING` (in yellow) when the container is paused by Auto-Sleep, distinct from `● ONLINE` and `● OFFLINE`.

### Known limitation

Only the HTTP port (8096) is covered. Jellyfin's direct HTTPS port (8920), if you use it, stays published normally and doesn't go through the wake proxy.

## Troubleshooting

**The "Media Storage" selector can't find a partition's UUID**
The script uses `lsblk` (no root needed) as the primary method for reading UUID/label/filesystem, and only falls back to `sudo blkid` if `lsblk` can't resolve it. If it still fails, check `sudo blkid <device>` manually.

**QSV/VA-API doesn't quite work / high power draw at "idle"**
Use **Configuration → 3. Hardware Acceleration Diagnostics**. The usual culprits are:
- Missing `group_add` with the `render` group's GID (the script now adds this automatically when configuring hardware acceleration).
- Hardware acceleration not actually enabled inside Jellyfin itself (Dashboard → Playback).
- A stuck `ffmpeg` process retrying a failed transcode — the diagnostics catch this.

**Intermittent playback errors ("A player error has occurred")**
If you use `powertop --auto-tune` or similar, check that your media disk doesn't have aggressive USB autosuspend or SATA Active Link Power Management enabled — this can cause I/O errors mid-playback. Exclude that specific device with a `udev` rule instead of disabling power saving entirely.

**`jellyfin-idle-watch.service` fails**
Check:
```bash
sudo systemctl status jellyfin-idle-watch.service --no-pager
sudo journalctl -u jellyfin-idle-watch.service --no-pager -n 50
```

## File layout

```
jellyfin-manager.sh
jellyfin/
├── docker-compose.yml
├── .env                  # media path, hwaccel, API key, auto-sleep config
├── config/               # Jellyfin configuration (persistent)
├── cache/
├── transcodes/
└── wake/                 # Auto-Sleep scripts and state
    ├── wake-relay.sh
    ├── idle-watch.sh
    ├── last-wake.ts
    └── idle-since.ts
```
