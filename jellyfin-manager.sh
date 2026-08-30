#!/usr/bin/env bash

set -o pipefail

# ============================================================
# Jellyfin Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JELLYFIN_DIR="$SCRIPT_DIR/jellyfin"
BACKUP_DIR="$SCRIPT_DIR/backups"

COMPOSE_FILE="$JELLYFIN_DIR/docker-compose.yml"
ENV_FILE="$JELLYFIN_DIR/.env"

CONTAINER_NAME="jellyfin"

MEDIA_MOUNT="/mnt/jellyfin-media"

# Hardware acceleration:
# software
# qsv
# vaapi
# nvidia
HARDWARE_ACCELERATION="software"

# Media disk information
MEDIA_DEVICE=""
MEDIA_UUID=""
MEDIA_FSTYPE=""
MEDIA_LABEL=""

# ============================================================
# Colours
# ============================================================

if [[ -t 1 ]]; then
    RESET="\033[0m"
    BOLD="\033[1m"
    DIM="\033[2m"
    GREEN="\033[32m"
    RED="\033[31m"
    YELLOW="\033[33m"
    CYAN="\033[36m"
else
    RESET=""
    BOLD=""
    DIM=""
    GREEN=""
    RED=""
    YELLOW=""
    CYAN=""
fi

# ============================================================
# UI
# ============================================================

clear_screen() {
    clear 2>/dev/null || true
}

header() {
    clear_screen

    echo
    echo -e "${BOLD}Jellyfin Manager${RESET}"
    echo "────────────────────────────────────────"
    echo
}

success() {
    echo -e "${GREEN}✓${RESET} $1"
}

error() {
    echo -e "${RED}✗${RESET} $1"
}

warning() {
    echo -e "${YELLOW}!${RESET} $1"
}

info() {
    echo -e "${CYAN}›${RESET} $1"
}

pause() {
    echo
    read -r -p "Press Enter to continue..."
}

confirm() {
    local answer

    read -r -p "$1 [y/N]: " answer

    [[ "$answer" =~ ^[Yy]$ ]]
}

# ============================================================
# Docker
# ============================================================

check_docker() {

    if ! command -v docker >/dev/null 2>&1; then
        error "Docker is not installed."
        return 1
    fi

    if ! docker info >/dev/null 2>&1; then

        if docker info 2>&1 | grep -qi "permission denied"; then

            error "Docker is installed, but this user can't talk to it."
            echo
            info "Fix it once:"
            echo
            echo "  sudo usermod -aG docker \$USER"
            echo "  newgrp docker"
            echo
            info "Or log out and log back in."
            echo

        else

            error "The Docker daemon isn't running or isn't reachable."
            echo
            info "Try: sudo systemctl start docker"
            echo

        fi

        return 1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose is not installed."
        return 1
    fi

    return 0
}

compose() {

    (
        cd "$JELLYFIN_DIR" || exit 1
        docker compose "$@"
    )
}

# ============================================================
# Jellyfin validation
# ============================================================

check_jellyfin() {

    if [[ ! -d "$JELLYFIN_DIR" ]]; then
        error "Jellyfin is not installed."
        return 1
    fi

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        error "docker-compose.yml not found."
        return 1
    fi

    return 0
}

# ============================================================
# Dependencies
# ============================================================

install_dependencies() {

    local missing=()

    command -v git >/dev/null 2>&1 || missing+=("git")
    command -v lsblk >/dev/null 2>&1 || missing+=("util-linux")
    command -v findmnt >/dev/null 2>&1 || missing+=("util-linux")

    if [[ ${#missing[@]} -eq 0 ]]; then
        success "System dependencies ready."
        return 0
    fi

    info "Installing system dependencies..."

    if command -v apt >/dev/null 2>&1; then

        sudo apt update

        sudo apt install -y \
            git \
            util-linux \
            mount \
            udisks2 \
            exfatprogs

    elif command -v dnf >/dev/null 2>&1; then

        sudo dnf install -y \
            git \
            util-linux \
            mount \
            udisks2 \
            exfatprogs

    else

        error "Unsupported package manager."
        error "Please install git, util-linux and exfatprogs manually."

        return 1
    fi

    success "System dependencies installed."
}

# ============================================================
# Docker installation
# ============================================================

install_docker() {

    if command -v docker >/dev/null 2>&1 &&
       docker compose version >/dev/null 2>&1; then

        success "Docker and Docker Compose are already installed."
        return 0
    fi

    echo
    info "Docker is required by Jellyfin Manager."
    echo

    if ! confirm "Install Docker now?"; then
        error "Docker is required."
        return 1
    fi

    if command -v apt >/dev/null 2>&1; then

        sudo apt update

        sudo apt install -y \
            ca-certificates \
            curl \
            gnupg

        sudo install \
            -m 0755 \
            -d \
            /etc/apt/keyrings

        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then

            sudo curl -fsSL \
                https://download.docker.com/linux/debian/gpg \
                -o /etc/apt/keyrings/docker.asc

        fi

        sudo chmod a+r \
            /etc/apt/keyrings/docker.asc

        . /etc/os-release

        local docker_repo_os="debian"

        if [[ "$ID" == "ubuntu" ]]; then
            docker_repo_os="ubuntu"
        fi

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$docker_repo_os \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" |
            sudo tee /etc/apt/sources.list.d/docker.list \
            >/dev/null

        sudo apt update

        sudo apt install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

    elif command -v dnf >/dev/null 2>&1; then

        sudo dnf -y install \
            dnf-plugins-core

        sudo dnf-3 config-manager \
            --add-repo \
            https://download.docker.com/linux/fedora/docker-ce.repo

        sudo dnf install -y \
            docker-ce \
            docker-ce-cli \
            containerd.io \
            docker-buildx-plugin \
            docker-compose-plugin

        sudo systemctl enable --now docker

    else

        error "Unsupported distribution."
        return 1
    fi

    sudo systemctl enable --now docker

    sudo usermod -aG docker "$USER"

    echo
    success "Docker installed."
    warning "Your user was added to the docker group."
    warning "Log out and back in before using Docker without sudo."
    echo

    return 1
}

# ============================================================
# Timezone
# ============================================================

get_timezone() {

    local timezone=""

    if command -v timedatectl >/dev/null 2>&1; then

        timezone="$(
            timedatectl show \
                --value \
                --property=Timezone \
                2>/dev/null
        )"

    fi

    if [[ -z "$timezone" ]] &&
       [[ -f /etc/timezone ]]; then

        timezone="$(cat /etc/timezone)"

    fi

    [[ -z "$timezone" ]] && timezone="UTC"

    echo "$timezone"
}

# ============================================================
# Media storage
# ============================================================

detect_media_partitions() {

    lsblk \
        -rpo NAME,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS \
        2>/dev/null |
    awk '
        NR > 1 &&
        $2 != "" &&
        $4 != "" {
            print
        }
    '
}

select_media_drive() {

    header

    echo "Media Storage"
    echo "────────────────────────────────────────"
    echo

    info "Available partitions:"
    echo

    mapfile -t partitions < <(
        detect_media_partitions
    )

    if [[ ${#partitions[@]} -eq 0 ]]; then

        error "No partitions with a filesystem and UUID were found."
        echo

        pause
        return 1
    fi

    local i=1
    local line

    for line in "${partitions[@]}"; do

        local device
        local fstype
        local label
        local uuid
        local size
        local mount

        read -r \
            device \
            fstype \
            label \
            uuid \
            size \
            mount <<< "$line"

        printf "  %2d) %-16s %-8s %-15s %-12s %s\n" \
            "$i" \
            "$device" \
            "$fstype" \
            "${label:--}" \
            "$size" \
            "$mount"

        i=$((i + 1))
    done

    echo
    echo "  0) Cancel"
    echo

    local choice

    read -r -p "Select media partition: " choice

    [[ "$choice" == "0" ]] && return 0

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then

        error "Invalid selection."
        pause
        return 1
    fi

    local index=$((choice - 1))

    if (( index < 0 || index >= ${#partitions[@]} )); then

        error "Invalid selection."
        pause
        return 1
    fi

    local selected="${partitions[$index]}"

    read -r \
        MEDIA_DEVICE \
        MEDIA_FSTYPE \
        MEDIA_LABEL \
        MEDIA_UUID \
        _ \
        _ <<< "$selected"

    echo

    success "Selected:"
    echo
    echo "  Device : $MEDIA_DEVICE"
    echo "  UUID   : $MEDIA_UUID"
    echo "  Type   : $MEDIA_FSTYPE"
    echo "  Label  : ${MEDIA_LABEL:--}"
    echo

    if [[ -z "$MEDIA_UUID" ]]; then

        error "Could not determine partition UUID."
        pause
        return 1
    fi

    return 0
}

save_media_config() {

    mkdir -p "$JELLYFIN_DIR"

    cat > "$ENV_FILE" << EOF
# Jellyfin Manager configuration

MEDIA_MOUNT=$MEDIA_MOUNT
MEDIA_DEVICE=$MEDIA_DEVICE
MEDIA_UUID=$MEDIA_UUID
MEDIA_FSTYPE=$MEDIA_FSTYPE
MEDIA_LABEL=$MEDIA_LABEL
HARDWARE_ACCELERATION=$HARDWARE_ACCELERATION
EOF
}

load_media_config() {

    if [[ -f "$ENV_FILE" ]]; then

        # shellcheck disable=SC1090
        source "$ENV_FILE"

    fi

    MEDIA_MOUNT="${MEDIA_MOUNT:-/mnt/jellyfin-media}"
    HARDWARE_ACCELERATION="${HARDWARE_ACCELERATION:-software}"
}

configure_fstab() {

    if [[ -z "$MEDIA_UUID" ]]; then
        error "Media UUID is not configured."
        return 1
    fi

    sudo mkdir -p "$MEDIA_MOUNT"

    local options="defaults,nofail,x-systemd.automount,x-systemd.device-timeout=10s"

    if [[ "$MEDIA_FSTYPE" == "exfat" ]]; then
        options="defaults,nofail,x-systemd.automount,x-systemd.device-timeout=10s"
    fi

    local fstab_line

    fstab_line="UUID=$MEDIA_UUID $MEDIA_MOUNT $MEDIA_FSTYPE $options 0 0"

    sudo sed -i "\|[[:space:]]$MEDIA_MOUNT[[:space:]]|d" /etc/fstab

    echo "$fstab_line" |
        sudo tee -a /etc/fstab >/dev/null

    sudo systemctl daemon-reload

    success "Automatic media mounting configured."
    echo
    echo "  UUID       : $MEDIA_UUID"
    echo "  Mount point: $MEDIA_MOUNT"
    echo

    return 0
}

mount_media() {

    sudo mkdir -p "$MEDIA_MOUNT"

    if mountpoint -q "$MEDIA_MOUNT"; then

        success "Media drive is already mounted."
        return 0
    fi

    info "Mounting media drive..."

    if sudo mount "$MEDIA_MOUNT"; then

        success "Media drive mounted."
        return 0
    fi

    error "Failed to mount media drive."
    return 1
}

unmount_media() {

    if ! mountpoint -q "$MEDIA_MOUNT"; then

        warning "Media drive is not mounted."
        return 0
    fi

    info "Unmounting media drive..."

    if sudo umount "$MEDIA_MOUNT"; then

        success "Media drive unmounted."
        return 0
    fi

    error "Failed to unmount media drive."
    return 1
}

media_status() {

    echo

    if mountpoint -q "$MEDIA_MOUNT"; then

        echo -e "Media Storage   ${GREEN}● MOUNTED${RESET}"

        local device

        device="$(
            findmnt \
                -n \
                -o SOURCE \
                --target "$MEDIA_MOUNT" \
                2>/dev/null
        )"

        echo "  Mount point   : $MEDIA_MOUNT"
        echo "  Device        : ${device:-unknown}"

    else

        echo -e "Media Storage   ${RED}● NOT MOUNTED${RESET}"
        echo "  Mount point   : $MEDIA_MOUNT"

    fi
}

configure_media_storage() {

    header

    load_media_config

    echo "Media Storage"
    echo "────────────────────────────────────────"
    echo

    if [[ -n "$MEDIA_UUID" ]]; then

        echo "Current configuration:"
        echo
        echo "  UUID        : $MEDIA_UUID"
        echo "  Device      : ${MEDIA_DEVICE:-unknown}"
        echo "  Filesystem  : ${MEDIA_FSTYPE:-unknown}"
        echo "  Label       : ${MEDIA_LABEL:--}"
        echo "  Mount point : $MEDIA_MOUNT"
        echo

    else

        warning "No media drive configured."
        echo

    fi

    echo "  1) Select Media Drive"
    echo "  2) Mount Media Drive"
    echo "  3) Unmount Media Drive"
    echo "  4) Media Status"
    echo
    echo "  0) Back"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            if select_media_drive; then

                echo

                if configure_fstab; then

                    save_media_config

                    echo
                    info "Media storage configuration saved."

                fi
            fi

            pause
            ;;

        2)

            mount_media
            pause
            ;;

        3)

            unmount_media
            pause
            ;;

        4)

            media_status
            pause
            ;;

        0)
            return
            ;;

        *)
            error "Invalid selection."
            sleep 1
            ;;

    esac
}

# ============================================================
# Hardware detection
# ============================================================

detect_intel_gpu() {

    command -v lspci >/dev/null 2>&1 || return 1

    lspci 2>/dev/null |
        grep -qiE 'VGA|3D|Display' &&
    lspci 2>/dev/null |
        grep -qi 'Intel'
}

detect_amd_gpu() {

    command -v lspci >/dev/null 2>&1 || return 1

    lspci 2>/dev/null |
        grep -qiE 'VGA|3D|Display' &&
    lspci 2>/dev/null |
        grep -qiE 'AMD|ATI'
}

detect_nvidia_gpu() {

    if command -v nvidia-smi >/dev/null 2>&1; then

        nvidia-smi >/dev/null 2>&1
        return $?
    fi

    command -v lspci >/dev/null 2>&1 || return 1

    lspci 2>/dev/null |
        grep -qiE 'VGA|3D|Display' &&
    lspci 2>/dev/null |
        grep -qi 'NVIDIA'
}

check_dri() {

    [[ -d /dev/dri ]] || return 1
    [[ -e /dev/dri/renderD128 ]]
}

check_nvidia_runtime() {

    command -v nvidia-container-cli >/dev/null 2>&1 ||
    command -v nvidia-ctk >/dev/null 2>&1
}

hardware_status() {

    echo
    echo "Hardware Detection"
    echo "────────────────────────────────────────"
    echo

    if detect_intel_gpu; then
        echo -e "Intel GPU       ${GREEN}● DETECTED${RESET}"
    else
        echo -e "Intel GPU       ${DIM}○ NOT DETECTED${RESET}"
    fi

    if detect_amd_gpu; then
        echo -e "AMD GPU         ${GREEN}● DETECTED${RESET}"
    else
        echo -e "AMD GPU         ${DIM}○ NOT DETECTED${RESET}"
    fi

    if detect_nvidia_gpu; then
        echo -e "NVIDIA GPU      ${GREEN}● DETECTED${RESET}"
    else
        echo -e "NVIDIA GPU      ${DIM}○ NOT DETECTED${RESET}"
    fi

    echo

    if check_dri; then
        echo -e "/dev/dri        ${GREEN}● AVAILABLE${RESET}"
    else
        echo -e "/dev/dri        ${RED}● NOT AVAILABLE${RESET}"
    fi

    if check_nvidia_runtime; then
        echo -e "NVIDIA Runtime  ${GREEN}● AVAILABLE${RESET}"
    else
        echo -e "NVIDIA Runtime  ${DIM}○ NOT AVAILABLE${RESET}"
    fi

    echo
}

configure_hardware_acceleration() {

    header

    load_media_config

    echo "Hardware Acceleration"
    echo "────────────────────────────────────────"
    echo

    case "$HARDWARE_ACCELERATION" in

        software)
            echo "Current: Software (CPU)"
            ;;

        qsv)
            echo "Current: Intel Quick Sync"
            ;;

        vaapi)
            echo "Current: AMD VA-API"
            ;;

        nvidia)
            echo "Current: NVIDIA NVENC / NVDEC"
            ;;

        *)
            echo "Current: Unknown"
            ;;

    esac

    echo
    echo "  1) Software (CPU)"
    echo "  2) Auto Detect GPU"
    echo "  3) Intel Quick Sync"
    echo "  4) AMD VA-API"
    echo "  5) NVIDIA NVENC / NVDEC"
    echo
    echo "  6) Check Hardware"
    echo
    echo "  0) Back"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            HARDWARE_ACCELERATION="software"

            save_media_config

            success "Hardware acceleration disabled."
            ;;

        2)

            if detect_intel_gpu && check_dri; then

                HARDWARE_ACCELERATION="qsv"
                success "Intel Quick Sync detected."

            elif detect_amd_gpu && check_dri; then

                HARDWARE_ACCELERATION="vaapi"
                success "AMD VA-API detected."

            elif detect_nvidia_gpu &&
                 check_nvidia_runtime; then

                HARDWARE_ACCELERATION="nvidia"
                success "NVIDIA acceleration detected."

            else

                HARDWARE_ACCELERATION="software"

                warning "No supported GPU configuration was detected."
                warning "Using software transcoding."

            fi

            save_media_config
            ;;

        3)

            if ! detect_intel_gpu; then

                warning "Intel GPU was not detected."
                echo

                if ! confirm "Enable Quick Sync anyway?"; then
                    return
                fi

            fi

            HARDWARE_ACCELERATION="qsv"

            save_media_config

            success "Intel Quick Sync selected."
            ;;

        4)

            if ! detect_amd_gpu; then

                warning "AMD GPU was not detected."
                echo

                if ! confirm "Enable AMD VA-API anyway?"; then
                    return
                fi

            fi

            HARDWARE_ACCELERATION="vaapi"

            save_media_config

            success "AMD VA-API selected."
            ;;

        5)

            if ! detect_nvidia_gpu; then

                warning "NVIDIA GPU was not detected."
                echo

                if ! confirm "Enable NVIDIA acceleration anyway?"; then
                    return
                fi

            fi

            HARDWARE_ACCELERATION="nvidia"

            save_media_config

            success "NVIDIA NVENC/NVDEC selected."
            ;;

        6)

            hardware_status
            pause
            return
            ;;

        0)
            return
            ;;

        *)
            error "Invalid selection."
            sleep 1
            return
            ;;

    esac

    echo
    warning "Restart Jellyfin for the new hardware configuration to take effect."

    pause
}

# ============================================================
# Docker Compose generation
# ============================================================

generate_compose() {

    load_media_config

    mkdir -p "$JELLYFIN_DIR"

    local timezone
    timezone="$(get_timezone)"

    case "$HARDWARE_ACCELERATION" in

        software)

            cat > "$COMPOSE_FILE" << EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped

    environment:
      - TZ=$timezone

    ports:
      - "8096:8096"
      - "8920:8920"

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro
EOF
            ;;

        qsv|vaapi)

            cat > "$COMPOSE_FILE" << EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped

    environment:
      - TZ=$timezone

    ports:
      - "8096:8096"
      - "8920:8920"

    devices:
      - /dev/dri:/dev/dri

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro
EOF
            ;;

        nvidia)

            cat > "$COMPOSE_FILE" << EOF
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: $CONTAINER_NAME
    restart: unless-stopped

    environment:
      - TZ=$timezone
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

    ports:
      - "8096:8096"
      - "8920:8920"

    gpus: all

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro
EOF
            ;;

        *)

            error "Unknown hardware acceleration mode."
            return 1
            ;;

    esac

    success "Docker Compose configuration generated."

    return 0
}

# ============================================================
# Configuration menu
# ============================================================

configuration_menu() {

    while true; do

        header

        load_media_config

        echo "Configuration"
        echo "────────────────────────────────────────"
        echo

        echo "  1) Media Storage"
        echo "  2) Hardware Acceleration"
        echo
        echo "  0) Back"
        echo

        local choice

        read -r -p "Select: " choice

        case "$choice" in

            1)
                configure_media_storage
                ;;

            2)

                configure_hardware_acceleration

                if check_jellyfin >/dev/null 2>&1; then
                    generate_compose
                fi

                ;;

            0)
                return
                ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Start
# ============================================================

start_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    load_media_config

    echo "Start"
    echo "────────────────────────────────────────"
    echo

    # --------------------------------------------------------
    # Media drive
    # --------------------------------------------------------

    if [[ -n "$MEDIA_UUID" ]]; then

        info "Checking media storage..."

        if ! mountpoint -q "$MEDIA_MOUNT"; then

            warning "Media drive is not currently mounted."
            info "Attempting to mount it..."

            if ! mount_media; then

                error "Media drive could not be mounted."
                echo
                warning "Jellyfin will NOT be started."
                pause
                return

            fi

        else

            success "Media storage is mounted."

        fi

        echo

    else

        warning "No media storage has been configured."
        echo
        warning "Jellyfin will be started without the media drive."
        echo

        if ! confirm "Continue?"; then
            return
        fi

    fi

    # --------------------------------------------------------
    # Generate compose
    # --------------------------------------------------------

    generate_compose || {
        pause
        return
    }

    echo

    # --------------------------------------------------------
    # Start Jellyfin
    # --------------------------------------------------------

    info "Starting Jellyfin..."

    if compose up -d; then

        echo
        success "Jellyfin started."

    else

        echo
        error "Failed to start Jellyfin."
        pause
        return

    fi

    pause
}

# ============================================================
# Stop
# ============================================================

stop_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    info "Stopping Jellyfin..."

    if compose stop; then

        success "Jellyfin stopped."

    else

        error "Failed to stop Jellyfin."

    fi

    pause
}

# ============================================================
# Restart
# ============================================================

restart_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    load_media_config

    info "Checking media storage..."

    if [[ -n "$MEDIA_UUID" ]] &&
       ! mountpoint -q "$MEDIA_MOUNT"; then

        info "Media drive is not mounted."
        info "Attempting to mount it..."

        if ! mount_media; then

            error "Media drive could not be mounted."
            pause
            return

        fi

    fi

    echo

    info "Restarting Jellyfin..."

    if compose restart; then

        success "Jellyfin restarted."

    else

        error "Failed to restart Jellyfin."

    fi

    pause
}

# ============================================================
# Status
# ============================================================

status_jellyfin() {

    header

    load_media_config

    echo "Status"
    echo "────────────────────────────────────────"
    echo

    # --------------------------------------------------------
    # Jellyfin
    # --------------------------------------------------------

    local container_status

    container_status="$(
        docker inspect \
            --format '{{.State.Status}}' \
            "$CONTAINER_NAME" \
            2>/dev/null
    )"

    case "$container_status" in

        running)
            echo -e "Jellyfin        ${GREEN}● ONLINE${RESET}"
            ;;

        exited|dead)
            echo -e "Jellyfin        ${RED}● OFFLINE${RESET}"
            ;;

        *)
            echo -e "Jellyfin        ${DIM}○ NOT INSTALLED${RESET}"
            ;;

    esac

    # --------------------------------------------------------
    # Media
    # --------------------------------------------------------

    if mountpoint -q "$MEDIA_MOUNT"; then

        echo -e "Media Storage   ${GREEN}● MOUNTED${RESET}"

        local device

        device="$(
            findmnt \
                -n \
                -o SOURCE \
                --target "$MEDIA_MOUNT" \
                2>/dev/null
        )"

        echo "  Mount point   : $MEDIA_MOUNT"
        echo "  Device        : ${device:-unknown}"

    else

        echo -e "Media Storage   ${RED}● NOT MOUNTED${RESET}"
        echo "  Mount point   : $MEDIA_MOUNT"

    fi

    # --------------------------------------------------------
    # Hardware
    # --------------------------------------------------------

    echo

    case "$HARDWARE_ACCELERATION" in

        software)
            echo "Hardware        : Software (CPU)"
            ;;

        qsv)
            echo "Hardware        : Intel Quick Sync"
            ;;

        vaapi)
            echo "Hardware        : AMD VA-API"
            ;;

        nvidia)
            echo "Hardware        : NVIDIA NVENC / NVDEC"
            ;;

        *)
            echo "Hardware        : Not configured"
            ;;

    esac

    # --------------------------------------------------------
    # GPU device
    # --------------------------------------------------------

    if [[ "$HARDWARE_ACCELERATION" == "qsv" ||
          "$HARDWARE_ACCELERATION" == "vaapi" ]]; then

        if check_dri; then

            echo -e "GPU Device      ${GREEN}● AVAILABLE${RESET}"

        else

            echo -e "GPU Device      ${RED}● NOT AVAILABLE${RESET}"

        fi

    elif [[ "$HARDWARE_ACCELERATION" == "nvidia" ]]; then

        if command -v nvidia-smi >/dev/null 2>&1 &&
           nvidia-smi >/dev/null 2>&1; then

            echo -e "GPU Device      ${GREEN}● AVAILABLE${RESET}"

        else

            echo -e "GPU Device      ${RED}● NOT AVAILABLE${RESET}"

        fi

    else

        echo -e "GPU Device      ${DIM}○ NOT REQUIRED${RESET}"

    fi

    echo

    pause
}

# ============================================================
# Logs
# ============================================================

logs_jellyfin() {

    check_jellyfin || return 1

    compose logs -f --tail=100
}

# ============================================================
# Backup
# ============================================================

backup_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    mkdir -p "$BACKUP_DIR"

    local timestamp
    local backup_file

    timestamp="$(date +%F_%H-%M-%S)"

    backup_file="$BACKUP_DIR/jellyfin-$timestamp.tar.gz"

    info "Creating Jellyfin backup..."
    echo

    info "Stopping Jellyfin temporarily..."

    compose stop >/dev/null 2>&1

    tar \
        -czf "$backup_file" \
        -C "$JELLYFIN_DIR" \
        config cache 2>/dev/null

    local result=$?

    compose start >/dev/null 2>&1

    echo

    if [[ "$result" -eq 0 ]]; then

        success "Backup completed."
        echo
        echo "  $backup_file"

    else

        error "Backup failed."
        rm -f "$backup_file"

    fi

    pause
}

# ============================================================
# Restore
# ============================================================

restore_jellyfin() {

    header

    mkdir -p "$BACKUP_DIR"

    mapfile -t backups < <(
        find "$BACKUP_DIR" \
            -maxdepth 1 \
            -type f \
            -name 'jellyfin-*.tar.gz' \
            -printf '%f\n' |
        sort -r
    )

    if [[ ${#backups[@]} -eq 0 ]]; then

        error "No Jellyfin backups found."
        pause
        return

    fi

    echo "Restore"
    echo "────────────────────────────────────────"
    echo

    local i=1
    local backup

    for backup in "${backups[@]}"; do

        echo "  $i) $backup"

        i=$((i + 1))
    done

    echo
    echo "  0) Cancel"
    echo

    local choice

    read -r -p "Select backup: " choice

    [[ "$choice" == "0" ]] && return

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then

        error "Invalid selection."
        pause
        return

    fi

    local index=$((choice - 1))

    if (( index < 0 || index >= ${#backups[@]} )); then

        error "Invalid selection."
        pause
        return

    fi

    local selected="$BACKUP_DIR/${backups[$index]}"

    echo
    warning "This will replace the current Jellyfin configuration."
    echo

    if ! confirm "Continue?"; then
        return
    fi

    check_docker || {
        pause
        return
    }

    if [[ -d "$JELLYFIN_DIR/config" ]]; then

        mv \
            "$JELLYFIN_DIR/config" \
            "$JELLYFIN_DIR/config.before-restore-$(date +%s)"

    fi

    if [[ -d "$JELLYFIN_DIR/cache" ]]; then

        mv \
            "$JELLYFIN_DIR/cache" \
            "$JELLYFIN_DIR/cache.before-restore-$(date +%s)"

    fi

    mkdir -p "$JELLYFIN_DIR"

    info "Restoring backup..."

    tar \
        -xzf "$selected" \
        -C "$JELLYFIN_DIR"

    local result=$?

    if [[ "$result" -eq 0 ]]; then

        success "Restore completed."

        info "Starting Jellyfin..."

        compose up -d

    else

        error "Restore failed."

    fi

    pause
}

# ============================================================
# Backup & Restore menu
# ============================================================

backup_menu() {

    while true; do

        header

        echo "Backup & Restore"
        echo "────────────────────────────────────────"
        echo

        echo "  1) Backup"
        echo "  2) Restore"
        echo
        echo "  0) Back"
        echo

        local choice

        read -r -p "Select: " choice

        case "$choice" in

            1)
                backup_jellyfin
                ;;

            2)
                restore_jellyfin
                ;;

            0)
                return
                ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Install
# ============================================================

install_jellyfin() {

    header

    echo "Install"
    echo "────────────────────────────────────────"
    echo

    if [[ -d "$JELLYFIN_DIR" ]]; then

        warning "Jellyfin is already installed."
        echo
        echo "  $JELLYFIN_DIR"
        echo

        pause
        return
    fi

    # --------------------------------------------------------
    # Dependencies
    # --------------------------------------------------------

    if ! install_dependencies; then

        pause
        return

    fi

    echo

    if ! install_docker; then

        pause
        return

    fi

    echo

    if ! check_docker; then

        pause
        return

    fi

    # --------------------------------------------------------
    # Directories
    # --------------------------------------------------------

    mkdir -p \
        "$JELLYFIN_DIR/config" \
        "$JELLYFIN_DIR/cache" \
        "$BACKUP_DIR"

    HARDWARE_ACCELERATION="software"

    MEDIA_DEVICE=""
    MEDIA_UUID=""
    MEDIA_FSTYPE=""
    MEDIA_LABEL=""

    save_media_config

    # --------------------------------------------------------
    # Initial Compose
    # --------------------------------------------------------

    generate_compose

    echo

    success "Jellyfin configuration created."

    # --------------------------------------------------------
    # Media storage
    # --------------------------------------------------------

    echo
    echo "Media Storage"
    echo "────────────────────────────────────────"
    echo

    info "Jellyfin needs a mount point for your media disk."
    info "The disk will be identified by UUID, so changing USB ports"
    info "will not change the configured device."
    echo

    if confirm "Configure the media drive now?"; then

        select_media_drive

        if [[ -n "$MEDIA_UUID" ]]; then

            echo

            configure_fstab

            save_media_config

        fi

    else

        warning "Media storage configuration skipped."

    fi

    # --------------------------------------------------------
    # Hardware acceleration
    # --------------------------------------------------------

    echo
    echo "Hardware Acceleration"
    echo "────────────────────────────────────────"
    echo

    info "Hardware acceleration is optional."
    info "Software transcoding will be used by default."
    echo

    if confirm "Configure hardware acceleration now?"; then

        configure_hardware_acceleration

    fi

    # --------------------------------------------------------
    # Generate final Compose
    # --------------------------------------------------------

    load_media_config

    generate_compose

    echo

    success "Jellyfin installation completed."

    echo
    echo "Jellyfin directory:"
    echo "  $JELLYFIN_DIR"

    echo
    echo "Web interface:"
    echo "  http://localhost:8096"

    echo
    info "Add Movies, TV Shows and other libraries from the"
    info "Jellyfin web interface using:"
    echo
    echo "  /media"
    echo

    if [[ -n "$MEDIA_UUID" ]]; then

        success "Media drive is configured using UUID."
        info "The USB port can be changed without changing the configuration."

    fi

    echo

    if confirm "Start Jellyfin now?"; then

        start_jellyfin

    else

        info "Jellyfin remains OFFLINE."
        info "Use Start from the main menu."

        pause

    fi
}

# ============================================================
# Update
# ============================================================

update_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Update"
    echo "────────────────────────────────────────"
    echo

    info "Pulling the latest Jellyfin image..."
    echo

    if compose pull; then

        echo
        success "Jellyfin image updated."

    else

        error "Failed to pull the Jellyfin image."
        pause
        return

    fi

    echo

    info "Recreating Jellyfin container..."

    if compose up -d; then

        success "Jellyfin updated successfully."

    else

        error "Failed to recreate Jellyfin."

    fi

    pause
}

# ============================================================
# Uninstall
# ============================================================

uninstall_jellyfin() {

    header

    check_jellyfin || {
        pause
        return
    }

    echo "Uninstall"
    echo "────────────────────────────────────────"
    echo

    echo "  1) Remove Jellyfin"
    echo "  2) Remove Jellyfin + configuration"
    echo "  0) Cancel"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            echo
            warning "The Jellyfin container will be removed."
            warning "Configuration and media data will be preserved."
            echo

            if ! confirm "Continue?"; then
                return
            fi

            compose down

            success "Jellyfin container removed."
            info "Configuration remains in:"
            echo "  $JELLYFIN_DIR"

            ;;

        2)

            echo
            warning "This will remove Jellyfin and its configuration."
            warning "Your media files will NOT be deleted."
            echo

            if ! confirm "THIS CANNOT BE UNDONE. Continue?"; then
                return
            fi

            compose down

            rm -rf \
                "$JELLYFIN_DIR"

            success "Jellyfin completely removed."
            info "Your external media drive was not touched."

            ;;

        0)
            return
            ;;

        *)
            error "Invalid selection."
            ;;

    esac

    pause
}

# ============================================================
# Main menu
# ============================================================

main_menu() {

    while true; do

        header

        load_media_config

        # ----------------------------------------------------
        # Jellyfin status
        # ----------------------------------------------------

        if [[ -d "$JELLYFIN_DIR" ]] &&
           [[ -f "$COMPOSE_FILE" ]]; then

            local container_status

            container_status="$(
                docker inspect \
                    --format '{{.State.Status}}' \
                    "$CONTAINER_NAME" \
                    2>/dev/null
            )"

            case "$container_status" in

                running)
                    echo -e "Jellyfin        ${GREEN}● ONLINE${RESET}"
                    ;;

                exited|dead)
                    echo -e "Jellyfin        ${RED}● OFFLINE${RESET}"
                    ;;

                *)
                    echo -e "Jellyfin        ${DIM}○ NOT RUNNING${RESET}"
                    ;;

            esac

        else

            echo -e "Jellyfin        ${DIM}○ NOT INSTALLED${RESET}"

        fi

        # ----------------------------------------------------
        # Media status
        # ----------------------------------------------------

        if mountpoint -q "$MEDIA_MOUNT"; then

            echo -e "Media           ${GREEN}● MOUNTED${RESET}"

        elif [[ -n "$MEDIA_UUID" ]]; then

            echo -e "Media           ${RED}● NOT MOUNTED${RESET}"

        else

            echo -e "Media           ${DIM}○ NOT CONFIGURED${RESET}"

        fi

        # ----------------------------------------------------
        # Hardware status
        # ----------------------------------------------------

        case "$HARDWARE_ACCELERATION" in

            software)
                echo "Hardware        : Software"
                ;;

            qsv)
                echo "Hardware        : Intel Quick Sync"
                ;;

            vaapi)
                echo "Hardware        : AMD VA-API"
                ;;

            nvidia)
                echo "Hardware        : NVIDIA NVENC / NVDEC"
                ;;

            *)
                echo "Hardware        : Not configured"
                ;;

        esac

        echo
        echo "------------------------------------------------------------"
        echo

        echo "  1  Start"
        echo "  2  Stop"
        echo "  3  Restart"
        echo "  4  Status"
        echo "  5  Logs"

        echo
        echo "  6  Configuration"
        echo "  7  Backup & Restore"

        echo
        echo "------------------------------------------------------------"
        echo

        echo "  8  Update"
        echo "  9  Install Jellyfin"
        echo " 10  Uninstall Jellyfin"

        echo
        echo "------------------------------------------------------------"
        echo

        echo "  0  Exit"
        echo

        local choice

        read -r -p "Select: " choice

        case "$choice" in

            1)
                start_jellyfin
                ;;

            2)
                stop_jellyfin
                ;;

            3)
                restart_jellyfin
                ;;

            4)
                status_jellyfin
                ;;

            5)
                logs_jellyfin
                ;;

            6)
                configuration_menu
                ;;

            7)
                backup_menu
                ;;

            8)
                update_jellyfin
                ;;

            9)
                install_jellyfin
                ;;

            10)
                uninstall_jellyfin
                ;;

            0)
                clear_screen
                exit 0
                ;;

            *)
                error "Invalid selection."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Command line mode
# ============================================================

case "${1:-}" in

    install)
        install_jellyfin
        ;;

    uninstall)
        uninstall_jellyfin
        ;;

    start)
        start_jellyfin
        ;;

    stop)
        stop_jellyfin
        ;;

    restart)
        restart_jellyfin
        ;;

    status)
        status_jellyfin
        ;;

    logs)
        logs_jellyfin
        ;;

    backup)
        backup_jellyfin
        ;;

    restore)
        restore_jellyfin
        ;;

    update)
        update_jellyfin
        ;;

    *)
        main_menu
        ;;

esac
