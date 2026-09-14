# Jellyfin Manager

A simple Bash script to install and manage [Jellyfin](https://jellyfin.org/) with Docker.

## Features

- Docker installation
- Jellyfin installation and updates
- Start / Stop / Restart
- Status and logs
- External USB media storage
- UUID-based media mounting
- Hardware acceleration with auto-detection:
  - Intel Quick Sync
  - AMD VA-API
  - NVIDIA NVENC / NVDEC
- Hardware acceleration diagnostics
- Auto-Sleep: pauses Jellyfin when idle and wakes it up on the next connection
- Backup and restore
- Simple terminal menu

## Installation

```bash
git clone https://github.com/miqcasrag/jellyfin-manager.git
cd jellyfin-manager
chmod +x jellyfin-manager.sh
./jellyfin-manager.sh
```
