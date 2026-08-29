#!/usr/bin/env bash

set -euo pipefail

# ============================================================
# Jellyfin Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JELLYFIN_DIR="$SCRIPT_DIR/jellyfin"

CONFIG_DIR="$JELLYFIN_DIR/config"
CACHE_DIR="$JELLYFIN_DIR/cache"
BACKUP_DIR="$JELLYFIN_DIR/backups"
COMPOSE_FILE="$JELLYFIN_DIR/docker-compose.yml"

MEDIA_MOUNT="/mnt/jellyfin-media"
CONTAINER_NAME="jellyfin"
JELLYFIN_IMAGE="jellyfin/jellyfin:latest"

SYSTEMD_SERVICE="jellyfin-manager.service"

TIMEZONE="$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")"

HARDWARE_ACCELERATION="software"

MEDIA_DEVICE=""
MEDIA_UUID=""
MEDIA_FSTYPE=""

# ============================================================
# Colors
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ============================================================
# Helpers
# ============================================================

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

pause_screen() {
    echo
    read -rp "Press Enter to continue..."
}

require_sudo() {
    sudo -v
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ============================================================
# Docker
# ============================================================

install_docker() {

    if command_exists docker && docker compose version >/dev/null 2>&1; then
        success "Docker and Docker Compose are already installed."
        return
    fi

    info "Installing Docker..."

    require_sudo

    sudo apt-get update

    sudo apt-get install -y \
        ca-certificates \
        curl \
        gnupg

    sudo install -m 0755 -d /etc/apt/keyrings

    if [ ! -f /etc/apt/keyrings/docker.gpg ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
            sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    fi

    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    . /etc/os-release

    if [ "$ID" = "debian" ]; then
        DOCKER_DISTRO="debian"
    else
        DOCKER_DISTRO="ubuntu"
    fi

    ARCH="$(dpkg --print-architecture)"

    echo \
      "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DOCKER_DISTRO} ${VERSION_CODENAME} stable" |
      sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

    sudo apt-get update

    sudo apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    sudo systemctl enable --now docker

    if ! groups "$USER" | grep -qw docker; then
        sudo usermod -aG docker "$USER"
        warning "Your user was added to the docker group."
        warning "Log out and log in again for the change to take effect."
    fi

    success "Docker installed."
}

# ============================================================
# Directories
# ============================================================

prepare_directories() {

    mkdir -p "$JELLYFIN_DIR"
    mkdir -p "$CONFIG_DIR"
    mkdir -p "$CACHE_DIR"
    mkdir -p "$BACKUP_DIR"

    success "Jellyfin directories prepared."
}

# ============================================================
# Media partition detection
# ============================================================

get_media_partitions() {

    lsblk -nrpo NAME,SIZE,FSTYPE,LABEL,UUID,TYPE |
        awk '$6 == "part" && $3 != "" && $5 != "" {
            printf "%s|%s|%s|%s|%s\n", $1, $2, $3, $4, $5
        }'
}

# ============================================================
# Select Media Drive
# ============================================================

select_media_drive() {

    require_sudo

    local partitions
    partitions="$(get_media_partitions)"

    if [ -z "$partitions" ]; then
        warning "No suitable partitions were found."
        return 1
    fi

    echo
    echo "============================================================"
    echo " Select Media Drive"
    echo "============================================================"
    echo

    local count=0
    local device size fstype label uuid

    declare -a DEVICES
    declare -a SIZES
    declare -a FILESYSTEMS
    declare -a LABELS
    declare -a UUIDS

    while IFS='|' read -r device size fstype label uuid; do

        count=$((count + 1))

        DEVICES[$count]="$device"
        SIZES[$count]="$size"
        FILESYSTEMS[$count]="$fstype"
        LABELS[$count]="${label:-N/A}"
        UUIDS[$count]="$uuid"

        echo "  $count) $device"
        echo "     Size       : $size"
        echo "     Filesystem : $fstype"
        echo "     Label      : ${label:-N/A}"
        echo "     UUID       : $uuid"
        echo

    done <<< "$partitions"

    echo "  0) Cancel"
    echo

    local selection

    while true; do

        read -rp "Select a drive [0-$count]: " selection

        if [[ "$selection" == "0" ]]; then
            return 1
        fi

        if [[ "$selection" =~ ^[0-9]+$ ]] &&
           [ "$selection" -ge 1 ] &&
           [ "$selection" -le "$count" ]; then
            break
        fi

        warning "Invalid selection."
    done

    MEDIA_DEVICE="${DEVICES[$selection]}"
    MEDIA_FSTYPE="${FILESYSTEMS[$selection]}"
    MEDIA_UUID="${UUIDS[$selection]}"

    echo
    echo "============================================================"
    echo " Selected Media Drive"
    echo "============================================================"
    echo
    echo "Device       : $MEDIA_DEVICE"
    echo "Filesystem   : $MEDIA_FSTYPE"
    echo "UUID         : $MEDIA_UUID"
    echo "Mount point  : $MEDIA_MOUNT"
    echo

    read -rp "Use this drive? [Y/n]: " confirm
    confirm="${confirm:-Y}"

    [[ "$confirm" =~ ^[Yy]$ ]]
}

# ============================================================
# Configure systemd media mount
# ============================================================

configure_media_systemd() {

    require_sudo

    local mount_unit
    mount_unit="$(systemd-escape --path "$MEDIA_MOUNT").mount"

    info "Configuring automatic media mounting..."

    sudo mkdir -p "$MEDIA_MOUNT"

    # Configure /etc/fstab.
    sudo sed -i "\|[[:space:]]${MEDIA_MOUNT}[[:space:]]|d" /etc/fstab

    local options="defaults,nofail,x-systemd.device-timeout=60"

    echo "UUID=$MEDIA_UUID $MEDIA_MOUNT $MEDIA_FSTYPE $options 0 0" |
        sudo tee -a /etc/fstab >/dev/null

    sudo systemctl daemon-reload

    success "Automatic media mounting configured."
}

# ============================================================
# Configure Jellyfin systemd dependency
# ============================================================

configure_jellyfin_systemd() {

    require_sudo

    local jellyfin_path
    jellyfin_path="$(systemd-escape --path "$MEDIA_MOUNT").mount"

    local compose_path="$COMPOSE_FILE"

    info "Configuring Jellyfin startup dependency..."

    sudo tee "/etc/systemd/system/$SYSTEMD_SERVICE" >/dev/null <<EOF
[Unit]
Description=Jellyfin Docker Compose
Requires=$jellyfin_path
After=$jellyfin_path docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$JELLYFIN_DIR
ExecStart=/usr/bin/docker compose -f $compose_path up -d
ExecStop=/usr/bin/docker compose -f $compose_path down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable "$SYSTEMD_SERVICE"

    success "Jellyfin startup dependency configured."
}

# ============================================================
# Configure Media Drive
# ============================================================

configure_media_drive() {

    if ! select_media_drive; then
        return
    fi

    configure_media_systemd

    success "Media drive configured."
    echo
    echo "The drive will be mounted using UUID:"
    echo "  $MEDIA_UUID"
    echo
    echo "Mount point:"
    echo "  $MEDIA_MOUNT"
    echo
    echo "Changing the USB port will not change the mount."
}

# ============================================================
# Media Status
# ============================================================

media_status() {

    echo
    echo "Mount point:"
    echo "  $MEDIA_MOUNT"
    echo

    if findmnt -rn "$MEDIA_MOUNT" >/dev/null 2>&1; then
        success "Media drive is mounted."
        findmnt "$MEDIA_MOUNT"
    else
        warning "Media drive is NOT mounted."
    fi
}

# ============================================================
# Mount Media
# ============================================================

mount_media() {

    require_sudo

    if sudo mount "$MEDIA_MOUNT"; then
        success "Media drive mounted."
    else
        error "Could not mount media drive."
    fi
}

# ============================================================
# Unmount Media
# ============================================================

unmount_media() {

    require_sudo

    if sudo umount "$MEDIA_MOUNT"; then
        success "Media drive unmounted."
    else
        error "Could not unmount media drive."
    fi
}

# ============================================================
# GPU Detection
# ============================================================

detect_gpu() {

    if [ -e /dev/dri/renderD128 ]; then

        if lspci 2>/dev/null | grep -qi "Intel"; then
            echo "intel"
            return
        fi

        if lspci 2>/dev/null | grep -qi "AMD\|ATI"; then
            echo "amd"
            return
        fi
    fi

    if command_exists nvidia-smi &&
       nvidia-smi >/dev/null 2>&1; then
        echo "nvidia"
        return
    fi

    echo "software"
}

# ============================================================
# Hardware Acceleration
# ============================================================

select_hardware_acceleration() {

    echo
    echo "============================================================"
    echo " Hardware Acceleration"
    echo "============================================================"
    echo
    echo "  1) Software (CPU)"
    echo "  2) Auto Detect GPU"
    echo "  3) Intel Quick Sync"
    echo "  4) AMD VA-API"
    echo "  5) NVIDIA NVENC / NVDEC"
    echo "  0) Cancel"
    echo

    local option

    read -rp "Select an option [0-5]: " option

    case "$option" in

        1)
            HARDWARE_ACCELERATION="software"
            ;;

        2)
            HARDWARE_ACCELERATION="$(detect_gpu)"
            info "Detected GPU: $HARDWARE_ACCELERATION"
            ;;

        3)
            HARDWARE_ACCELERATION="intel"

            if [ ! -e /dev/dri/renderD128 ]; then
                warning "/dev/dri/renderD128 was not found."
            fi
            ;;

        4)
            HARDWARE_ACCELERATION="amd"

            if [ ! -e /dev/dri/renderD128 ]; then
                warning "/dev/dri/renderD128 was not found."
            fi
            ;;

        5)
            HARDWARE_ACCELERATION="nvidia"
            ;;

        0)
            return
            ;;

        *)
            warning "Invalid option."
            return
            ;;
    esac

    success "Hardware acceleration: $HARDWARE_ACCELERATION"

    generate_compose
}

# ============================================================
# Generate Docker Compose
# ============================================================

generate_compose() {

    mkdir -p "$JELLYFIN_DIR"

    cat > "$COMPOSE_FILE" <<EOF
services:
  jellyfin:
    image: $JELLYFIN_IMAGE
    container_name: $CONTAINER_NAME

    ports:
      - "8096:8096"

    environment:
      - TZ=$TIMEZONE

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro

    restart: unless-stopped
EOF

    case "$HARDWARE_ACCELERATION" in

        intel|amd)

            cat >> "$COMPOSE_FILE" <<EOF

    devices:
      - /dev/dri/renderD128:/dev/dri/renderD128
EOF

            local render_gid
            render_gid="$(getent group render | cut -d: -f3 || true)"

            if [ -n "$render_gid" ]; then

                cat >> "$COMPOSE_FILE" <<EOF

    group_add:
      - "$render_gid"
EOF

            fi
            ;;

        nvidia)

            cat >> "$COMPOSE_FILE" <<EOF

    gpus: all
EOF
            ;;

        software)
            ;;
    esac

    success "Docker Compose configuration generated."
}

# ============================================================
# Installation
# ============================================================

install_jellyfin() {

    install_docker
    prepare_directories

    echo
    echo "============================================================"
    echo " Jellyfin Installation"
    echo "============================================================"
    echo

    echo "Would you like to configure a media drive now?"
    echo
    echo "  1) Yes"
    echo "  2) No"
    echo

    local media_option

    while true; do

        read -rp "Select an option [1-2]: " media_option

        case "$media_option" in

            1)
                configure_media_drive
                break
                ;;

            2)
                info "Media drive configuration skipped."
                break
                ;;

            *)
                warning "Invalid option."
                ;;
        esac

    done

    echo
    echo "Hardware acceleration is optional."
    echo
    echo "  1) Software (CPU)"
    echo "  2) Configure Hardware Acceleration"
    echo

    local hardware_option

    read -rp "Select an option [1-2]: " hardware_option

    case "$hardware_option" in

        2)
            select_hardware_acceleration
            ;;

        *)
            HARDWARE_ACCELERATION="software"
            ;;
    esac

    generate_compose

    # If media was configured, recreate systemd dependency
    # after generating the final compose file.
    if grep -q "$MEDIA_MOUNT" /etc/fstab 2>/dev/null; then
        configure_jellyfin_systemd
    fi

    info "Pulling Jellyfin image..."

    docker compose -f "$COMPOSE_FILE" pull

    success "Jellyfin installation completed."

    echo
    echo "Jellyfin has NOT been started automatically."
    echo
    echo "Use the Start option from the manager."
}

# ============================================================
# Start
# ============================================================

start_jellyfin() {

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Jellyfin is not installed."
        return
    fi

    if grep -q "$MEDIA_MOUNT" /etc/fstab 2>/dev/null; then

        if ! findmnt -rn "$MEDIA_MOUNT" >/dev/null 2>&1; then
            error "Media drive is not mounted."
            warning "Jellyfin will not be started."
            return
        fi
    fi

    if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
        sudo systemctl start "$SYSTEMD_SERVICE"
    else
        docker compose -f "$COMPOSE_FILE" up -d
    fi

    success "Jellyfin started."
}

# ============================================================
# Stop
# ============================================================

stop_jellyfin() {

    if systemctl is-active "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
        sudo systemctl stop "$SYSTEMD_SERVICE"
    else
        docker compose -f "$COMPOSE_FILE" down
    fi

    success "Jellyfin stopped."
}

# ============================================================
# Restart
# ============================================================

restart_jellyfin() {

    stop_jellyfin
    start_jellyfin
}

# ============================================================
# Update
# ============================================================

update_jellyfin() {

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Jellyfin is not installed."
        return
    fi

    info "Pulling latest Jellyfin image..."

    docker compose -f "$COMPOSE_FILE" pull

    info "Recreating Jellyfin container..."

    if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
        sudo systemctl restart "$SYSTEMD_SERVICE"
    else
        docker compose -f "$COMPOSE_FILE" up -d
    fi

    success "Jellyfin updated."
}

# ============================================================
# Recreate Container
# ============================================================

recreate_container() {

    docker compose -f "$COMPOSE_FILE" up -d --force-recreate

    success "Jellyfin container recreated."
}

# ============================================================
# Status
# ============================================================

status_jellyfin() {

    echo
    echo "============================================================"
    echo " Jellyfin Status"
    echo "============================================================"
    echo

    if [ -f "$COMPOSE_FILE" ]; then
        docker compose -f "$COMPOSE_FILE" ps
    else
        warning "Jellyfin is not installed."
    fi

    echo
    media_status

    echo
    echo "Hardware acceleration:"
    echo "  $HARDWARE_ACCELERATION"

    echo
    echo "Automatic startup:"
    if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
        success "Enabled"
    else
        warning "Not configured"
    fi
}

# ============================================================
# Logs
# ============================================================

logs_jellyfin() {

    if [ ! -f "$COMPOSE_FILE" ]; then
        error "Jellyfin is not installed."
        return
    fi

    docker compose -f "$COMPOSE_FILE" logs -f jellyfin
}

# ============================================================
# Hardware Check
# ============================================================

verify_hardware() {

    echo
    echo "============================================================"
    echo " Hardware Acceleration Check"
    echo "============================================================"
    echo

    echo "Configured:"
    echo "  $HARDWARE_ACCELERATION"
    echo

    case "$HARDWARE_ACCELERATION" in

        intel|amd)

            if [ -e /dev/dri/renderD128 ]; then
                success "/dev/dri/renderD128 exists."
            else
                error "/dev/dri/renderD128 was not found."
            fi

            echo
            echo "Container GPU devices:"

            docker exec "$CONTAINER_NAME" \
                ls -la /dev/dri 2>/dev/null ||
                warning "Could not access /dev/dri inside the container."

            ;;

        nvidia)

            if command_exists nvidia-smi &&
               nvidia-smi >/dev/null 2>&1; then
                success "NVIDIA GPU detected."
                nvidia-smi
            else
                error "NVIDIA GPU is not available."
            fi
            ;;

        software)

            info "Software transcoding is enabled."
            ;;
    esac
}

# ============================================================
# Backup
# ============================================================

backup_jellyfin() {

    mkdir -p "$BACKUP_DIR"

    local timestamp
    local backup_file

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    backup_file="$BACKUP_DIR/jellyfin-backup-$timestamp.tar.gz"

    info "Stopping Jellyfin..."

    stop_jellyfin

    info "Creating backup..."

    tar -czf "$backup_file" \
        -C "$JELLYFIN_DIR" \
        config \
        docker-compose.yml

    start_jellyfin

    success "Backup created:"
    echo
    echo "$backup_file"
}

# ============================================================
# Restore
# ============================================================

restore_jellyfin() {

    echo
    echo "Available backups:"
    echo

    find "$BACKUP_DIR" \
        -maxdepth 1 \
        -type f \
        -name "*.tar.gz" \
        -printf '%f\n' |
        sort

    echo

    local backup_name

    read -rp "Enter backup filename: " backup_name

    local backup_file="$BACKUP_DIR/$backup_name"

    if [ ! -f "$backup_file" ]; then
        error "Backup not found."
        return
    fi

    warning "This will replace the current Jellyfin configuration."

    read -rp "Continue? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi

    stop_jellyfin

    info "Restoring backup..."

    tar -xzf "$backup_file" -C "$JELLYFIN_DIR"

    start_jellyfin

    success "Backup restored."
}

# ============================================================
# Configuration
# ============================================================

show_configuration() {

    echo
    echo "============================================================"
    echo " Configuration"
    echo "============================================================"
    echo

    echo "Script directory      : $SCRIPT_DIR"
    echo "Jellyfin directory    : $JELLYFIN_DIR"
    echo "Config directory      : $CONFIG_DIR"
    echo "Cache directory       : $CACHE_DIR"
    echo "Backup directory      : $BACKUP_DIR"
    echo "Media mount           : $MEDIA_MOUNT"
    echo "Timezone              : $TIMEZONE"
    echo "Hardware acceleration : $HARDWARE_ACCELERATION"

    echo

    if [ -f "$COMPOSE_FILE" ]; then
        echo "Docker Compose:"
        echo
        cat "$COMPOSE_FILE"
    fi
}

# ============================================================
# Remove Jellyfin
# ============================================================

remove_jellyfin() {

    warning "This will remove the Jellyfin container and configuration."
    echo
    echo "Media files will NOT be removed."
    echo

    read -rp "Continue? [y/N]: " confirm

    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        return
    fi

    if systemctl is-enabled "$SYSTEMD_SERVICE" >/dev/null 2>&1; then
        sudo systemctl disable --now "$SYSTEMD_SERVICE" || true
        sudo rm -f "/etc/systemd/system/$SYSTEMD_SERVICE"
        sudo systemctl daemon-reload
    fi

    docker compose -f "$COMPOSE_FILE" down 2>/dev/null || true

    rm -rf "$CONFIG_DIR"
    rm -rf "$CACHE_DIR"

    rm -f "$COMPOSE_FILE"

    success "Jellyfin removed."
}

# ============================================================
# Media Menu
# ============================================================

media_menu() {

    while true; do

        clear

        echo "============================================================"
        echo " Media Storage"
        echo "============================================================"
        echo
        echo "  1) Configure Media Drive"
        echo "  2) Mount Media Drive"
        echo "  3) Unmount Media Drive"
        echo "  4) Media Status"
        echo
        echo "  0) Back"
        echo

        local option

        read -rp "Select an option: " option

        case "$option" in

            1)
                configure_media_drive
                pause_screen
                ;;

            2)
                mount_media
                pause_screen
                ;;

            3)
                unmount_media
                pause_screen
                ;;

            4)
                media_status
                pause_screen
                ;;

            0)
                return
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# Backup Menu
# ============================================================

backup_menu() {

    while true; do

        clear

        echo "============================================================"
        echo " Backup & Restore"
        echo "============================================================"
        echo
        echo "  1) Create Backup"
        echo "  2) Restore Backup"
        echo
        echo "  0) Back"
        echo

        local option

        read -rp "Select an option: " option

        case "$option" in

            1)
                backup_jellyfin
                pause_screen
                ;;

            2)
                restore_jellyfin
                pause_screen
                ;;

            0)
                return
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# Main Menu
# ============================================================

main_menu() {

    while true; do

        clear

        echo "============================================================"
        echo "                    Jellyfin Manager"
        echo "============================================================"
        echo
        echo " Installation : $JELLYFIN_DIR"
        echo " Media        : $MEDIA_MOUNT"
        echo " Hardware     : $HARDWARE_ACCELERATION"
        echo
        echo "------------------------------------------------------------"
        echo
        echo "  1) Install Jellyfin"
        echo
        echo "  2) Start"
        echo "  3) Stop"
        echo "  4) Restart"
        echo
        echo "  5) Update"
        echo "  6) Recreate Container"
        echo
        echo "  7) Status"
        echo "  8) Logs"
        echo
        echo "  9) Media Storage"
        echo " 10) Hardware Acceleration"
        echo
        echo " 11) Backup & Restore"
        echo  " 12) Configuration"
        echo " 13) Hardware Check"
        echo
        echo " 14) Remove Jellyfin"
        echo
        echo "  0) Exit"
        echo
        echo "------------------------------------------------------------"

        local option

        read -rp "Select an option: " option

        case "$option" in

            1)
                install_jellyfin
                pause_screen
                ;;

            2)
                start_jellyfin
                pause_screen
                ;;

            3)
                stop_jellyfin
                pause_screen
                ;;

            4)
                restart_jellyfin
                pause_screen
                ;;

            5)
                update_jellyfin
                pause_screen
                ;;

            6)
                recreate_container
                pause_screen
                ;;

            7)
                status_jellyfin
                pause_screen
                ;;

            8)
                logs_jellyfin
                ;;

            9)
                media_menu
                ;;

            10)
                select_hardware_acceleration
                pause_screen
                ;;

            11)
                backup_menu
                ;;

            12)
                show_configuration
                pause_screen
                ;;

            13)
                verify_hardware
                pause_screen
                ;;

            14)
                remove_jellyfin
                pause_screen
                ;;

            0)
                clear
                exit 0
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;
        esac

    done
}

# ============================================================
# Main
# ============================================================

main() {
    main_menu
}

main "$@"
