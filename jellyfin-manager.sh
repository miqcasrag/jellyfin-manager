#!/usr/bin/env bash

set -o pipefail

# ============================================================
# Jellyfin Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JELLYFIN_DIR="$SCRIPT_DIR/jellyfin"

COMPOSE_FILE="$JELLYFIN_DIR/docker-compose.yml"

CONFIG_DIR="$JELLYFIN_DIR/config"
CACHE_DIR="$JELLYFIN_DIR/cache"
BACKUP_DIR="$JELLYFIN_DIR/backups"

MEDIA_MOUNT="/mnt/jellyfin-media"

JELLYFIN_IMAGE="jellyfin/jellyfin:latest"
JELLYFIN_CONTAINER="jellyfin"
JELLYFIN_PORT="8096"

CURRENT_USER="$(id -un)"

# Hardware acceleration:
# software | auto | intel | amd | nvidia
HARDWARE_ACCELERATION="software"

GPU_VENDOR="none"
GPU_NAME=""
GPU_DEVICE=""
GPU_GROUP=""
GPU_GID=""

# ============================================================
# Colors
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
# Privileges
# ============================================================

require_sudo() {
    if ! command -v sudo >/dev/null 2>&1; then
        error "sudo is required but was not found."
        return 1
    fi

    sudo -v
}

# ============================================================
# System
# ============================================================

check_supported_system() {
    if [[ ! -f /etc/os-release ]]; then
        error "Could not determine the operating system."
        return 1
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu)
            return 0
            ;;
        *)
            warning "This manager is designed for Debian/Ubuntu-based systems."
            return 1
            ;;
    esac
}

check_dependencies() {
    local missing=false

    for command in \
        awk \
        grep \
        sed \
        tar \
        lsblk \
        blkid \
        findmnt \
        mountpoint \
        stat; do

        if ! command -v "$command" >/dev/null 2>&1; then
            missing=true
        fi
    done

    [[ "$missing" == false ]] && return 0

    check_supported_system || return 1
    require_sudo || return 1

    info "Installing required system utilities..."

    sudo apt-get update || return 1

    sudo apt-get install -y \
        util-linux \
        tar \
        coreutils \
        grep \
        sed \
        gawk || return 1

    success "Required utilities installed."
}

# ============================================================
# Docker
# ============================================================

check_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    docker compose version >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1

    return 0
}

install_docker() {
    check_supported_system || return 1
    require_sudo || return 1

    if command -v docker >/dev/null 2>&1; then
        success "Docker is already installed."
    else
        info "Installing Docker..."

        sudo apt-get update || return 1

        sudo apt-get install -y \
            docker.io \
            docker-compose-plugin \
            ca-certificates \
            curl || return 1

        success "Docker installed."
    fi

    if ! docker compose version >/dev/null 2>&1; then
        info "Installing Docker Compose plugin..."

        sudo apt-get update || return 1
        sudo apt-get install -y docker-compose-plugin || return 1
    fi

    sudo systemctl enable docker >/dev/null 2>&1 || true
    sudo systemctl start docker || return 1

    if ! getent group docker >/dev/null 2>&1; then
        sudo groupadd docker
    fi

    if ! id -nG "$CURRENT_USER" |
        tr ' ' '\n' |
        grep -qx "docker"; then

        info "Adding '$CURRENT_USER' to the docker group..."

        sudo usermod -aG docker "$CURRENT_USER"

        success "User added to docker group."

        warning "Log out and log in again before using Docker without sudo."

        return 0
    fi

    success "Docker is configured."

    if ! docker info >/dev/null 2>&1; then
        warning "Docker is not available to the current shell."
        warning "Log out and log in again."
        return 1
    fi

    success "Docker is ready."
}

ensure_docker() {
    if check_docker; then
        return 0
    fi

    warning "Docker or Docker Compose is unavailable."

    if confirm "Install/configure Docker now?"; then
        install_docker
    else
        error "Docker is required."
        return 1
    fi
}

compose() {
    (
        cd "$JELLYFIN_DIR" || exit 1
        docker compose "$@"
    )
}

# ============================================================
# Directories
# ============================================================

prepare_directories() {
    mkdir -p \
        "$JELLYFIN_DIR" \
        "$CONFIG_DIR" \
        "$CACHE_DIR" \
        "$BACKUP_DIR"

    success "Jellyfin directories are ready."
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

    if [[ -z "$timezone" ]] && [[ -f /etc/timezone ]]; then
        timezone="$(cat /etc/timezone)"
    fi

    [[ -z "$timezone" ]] && timezone="UTC"

    echo "$timezone"
}

# ============================================================
# Jellyfin checks
# ============================================================

check_jellyfin() {
    [[ -d "$JELLYFIN_DIR" ]] || {
        error "Jellyfin is not installed."
        return 1
    }

    [[ -f "$COMPOSE_FILE" ]] || {
        error "docker-compose.yml was not found."
        return 1
    }

    return 0
}

container_exists() {
    docker ps -a \
        --format '{{.Names}}' |
        grep -qx "$JELLYFIN_CONTAINER"
}

container_running() {
    docker ps \
        --format '{{.Names}}' |
        grep -qx "$JELLYFIN_CONTAINER"
}

# ============================================================
# Media
# ============================================================

is_media_mounted() {
    mountpoint -q "$MEDIA_MOUNT"
}

get_media_device() {
    findmnt -n -o SOURCE "$MEDIA_MOUNT" 2>/dev/null || true
}

get_media_uuid() {
    findmnt -n -o UUID "$MEDIA_MOUNT" 2>/dev/null || true
}

get_media_filesystem() {
    findmnt -n -o FSTYPE "$MEDIA_MOUNT" 2>/dev/null || true
}

check_media_fstab() {
    grep -q \
        "[[:space:]]$MEDIA_MOUNT[[:space:]]" \
        /etc/fstab 2>/dev/null
}

check_media() {
    if ! is_media_mounted; then
        error "Media drive is not mounted at $MEDIA_MOUNT."
        return 1
    fi

    local device
    device="$(get_media_device)"

    [[ -n "$device" ]] || {
        error "Could not determine the media device."
        return 1
    }

    success "Media drive mounted: $device"

    return 0
}

show_disks() {
    echo

    lsblk \
        -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MODEL,MOUNTPOINTS

    echo
}

configure_media() {
    require_sudo || return 1

    header

    echo -e "${BOLD}Configure Media Drive${RESET}"
    echo

    warning "The selected partition will NOT be formatted."
    warning "Existing files will NOT be deleted."
    echo

    show_disks

    echo "Enter the partition containing your media."
    echo "Example: /dev/sda1"
    echo

    local device

    read -r -p "Media partition: " device

    [[ -n "$device" ]] || {
        error "No partition selected."
        return 1
    }

    [[ -b "$device" ]] || {
        error "$device is not a valid block device."
        return 1
    }

    local uuid
    local filesystem
    local label

    uuid="$(blkid -s UUID -o value "$device" 2>/dev/null || true)"
    filesystem="$(blkid -s TYPE -o value "$device" 2>/dev/null || true)"
    label="$(blkid -s LABEL -o value "$device" 2>/dev/null || true)"

    [[ -n "$uuid" ]] || {
        error "Could not determine partition UUID."
        return 1
    }

    [[ -n "$filesystem" ]] || {
        error "Could not determine filesystem."
        return 1
    }

    echo
    echo "Selected partition:"
    echo
    echo "  Device      : $device"
    echo "  Filesystem  : $filesystem"
    echo "  UUID        : $uuid"
    echo "  Label       : ${label:-none}"
    echo "  Mount point : $MEDIA_MOUNT"
    echo

    confirm "Use this partition?" || {
        warning "Operation cancelled."
        return 1
    }

    sudo mkdir -p "$MEDIA_MOUNT"

    local fstab_backup

    fstab_backup="/etc/fstab.backup-jellyfin-$(date +%Y%m%d-%H%M%S)"

    sudo cp /etc/fstab "$fstab_backup"

    success "Created fstab backup:"
    echo "  $fstab_backup"

    sudo sed -i \
        "\|[[:space:]]$MEDIA_MOUNT[[:space:]]|d" \
        /etc/fstab

    local fstab_entry

    fstab_entry="UUID=$uuid $MEDIA_MOUNT $filesystem defaults,nofail,x-systemd.device-timeout=10 0 2"

    echo "$fstab_entry" |
        sudo tee -a /etc/fstab >/dev/null

    sudo systemctl daemon-reload

    success "Media drive configured using UUID."

    mount_media
}

mount_media() {
    require_sudo || return 1

    sudo mkdir -p "$MEDIA_MOUNT"

    if is_media_mounted; then
        success "Media drive is already mounted."
        return 0
    fi

    if ! check_media_fstab; then
        error "Media drive is not configured in /etc/fstab."
        return 1
    fi

    info "Mounting media drive..."

    if sudo mount "$MEDIA_MOUNT"; then
        success "Media drive mounted."
    else
        error "Failed to mount media drive."
        return 1
    fi

    check_media
}

unmount_media() {
    require_sudo || return 1

    if ! is_media_mounted; then
        warning "Media drive is not mounted."
        return 0
    fi

    if container_running; then
        warning "Jellyfin is currently running."

        if confirm "Stop Jellyfin before unmounting?"; then
            stop_jellyfin || return 1
        else
            warning "Unmount cancelled."
            return 1
        fi
    fi

    info "Unmounting media drive..."

    if sudo umount "$MEDIA_MOUNT"; then
        success "Media drive unmounted."
    else
        error "Failed to unmount media drive."
        return 1
    fi
}

# ============================================================
# GPU detection
# ============================================================

reset_gpu_detection() {
    GPU_VENDOR="none"
    GPU_NAME=""
    GPU_DEVICE=""
    GPU_GROUP=""
    GPU_GID=""
}

detect_dri_device() {
    local device

    for device in /dev/dri/renderD*; do
        if [[ -e "$device" ]]; then
            echo "$device"
            return 0
        fi
    done

    return 1
}

detect_gpu() {
    reset_gpu_detection

    # NVIDIA
    if command -v nvidia-smi >/dev/null 2>&1; then
        if nvidia-smi >/dev/null 2>&1; then
            GPU_VENDOR="nvidia"

            GPU_NAME="$(
                nvidia-smi \
                    --query-gpu=name \
                    --format=csv,noheader \
                    2>/dev/null |
                    head -n1
            )"

            return 0
        fi
    fi

    # lspci
    if ! command -v lspci >/dev/null 2>&1; then
        return 1
    fi

    local gpu_line

    gpu_line="$(
        lspci |
        grep -Ei \
            "VGA compatible controller|3D controller|Display controller" |
        head -n1
    )"

    [[ -n "$gpu_line" ]] || return 1

    case "$gpu_line" in

        *NVIDIA*|*nVidia*)
            GPU_VENDOR="nvidia"
            GPU_NAME="$gpu_line"
            ;;

        *AMD*|*ATI*|*Advanced\ Micro\ Devices*)
            GPU_VENDOR="amd"
            GPU_NAME="$gpu_line"
            ;;

        *Intel*)
            GPU_VENDOR="intel"
            GPU_NAME="$gpu_line"
            ;;

        *)
            GPU_VENDOR="none"
            return 1
            ;;

    esac

    if [[ "$GPU_VENDOR" == "intel" ||
          "$GPU_VENDOR" == "amd" ]]; then

        GPU_DEVICE="$(detect_dri_device || true)"

        if [[ -n "$GPU_DEVICE" ]]; then

            GPU_GROUP="$(
                stat -c '%G' "$GPU_DEVICE" 2>/dev/null || true
            )"

            [[ -n "$GPU_GROUP" ]] || GPU_GROUP="render"

            GPU_GID="$(
                getent group "$GPU_GROUP" |
                cut -d: -f3
            )"
        fi
    fi

    return 0
}

# ============================================================
# NVIDIA Toolkit
# ============================================================

check_nvidia_toolkit() {
    command -v nvidia-ctk >/dev/null 2>&1
}

install_nvidia_toolkit() {
    check_supported_system || return 1
    require_sudo || return 1

    if check_nvidia_toolkit; then
        success "NVIDIA Container Toolkit is already installed."
        return 0
    fi

    info "Installing NVIDIA Container Toolkit..."

    sudo apt-get update || return 1

    sudo apt-get install -y \
        curl \
        ca-certificates \
        gnupg || return 1

    curl -fsSL \
        https://nvidia.github.io/libnvidia-container/gpgkey |
        sudo gpg \
            --dearmor \
            --yes \
            -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
        || return 1

    curl -fsSL \
        https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list |
        sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' |
        sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list \
        >/dev/null \
        || return 1

    sudo apt-get update || return 1

    sudo apt-get install -y \
        nvidia-container-toolkit || return 1

    success "NVIDIA Container Toolkit installed."

    info "Configuring Docker NVIDIA runtime..."

    sudo nvidia-ctk runtime configure \
        --runtime=docker || return 1

    sudo systemctl restart docker || return 1

    success "Docker NVIDIA runtime configured."
}

# ============================================================
# Hardware acceleration selection
# ============================================================

hardware_acceleration_name() {
    case "$HARDWARE_ACCELERATION" in
        software)
            echo "Software (CPU)"
            ;;
        auto)
            echo "Auto Detect"
            ;;
        intel)
            echo "Intel Quick Sync"
            ;;
        amd)
            echo "AMD VA-API"
            ;;
        nvidia)
            echo "NVIDIA NVENC / NVDEC"
            ;;
        *)
            echo "Software (CPU)"
            ;;
    esac
}

select_hardware_acceleration() {
    while true; do

        header

        echo -e "${BOLD}Hardware Acceleration${RESET}"
        echo
        echo "Current mode:"
        echo "  $(hardware_acceleration_name)"
        echo

        echo "  1) Software (CPU)"
        echo "  2) Auto Detect GPU"
        echo "  3) Intel Quick Sync"
        echo "  4) AMD VA-API"
        echo "  5) NVIDIA NVENC / NVDEC"
        echo "  0) Back"
        echo

        read -r -p "Select an option [1]: " choice

        [[ -z "$choice" ]] && choice="1"

        case "$choice" in

            1)
                HARDWARE_ACCELERATION="software"
                apply_hardware_acceleration
                pause
                ;;

            2)
                HARDWARE_ACCELERATION="auto"
                apply_hardware_acceleration
                pause
                ;;

            3)
                HARDWARE_ACCELERATION="intel"
                apply_hardware_acceleration
                pause
                ;;

            4)
                HARDWARE_ACCELERATION="amd"
                apply_hardware_acceleration
                pause
                ;;

            5)
                HARDWARE_ACCELERATION="nvidia"
                apply_hardware_acceleration
                pause
                ;;

            0)
                return 0
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Compose generation
# ============================================================

write_compose() {
    prepare_directories

    local timezone
    timezone="$(get_timezone)"

    local acceleration="$HARDWARE_ACCELERATION"

    if [[ "$acceleration" == "auto" ]]; then

        detect_gpu

        case "$GPU_VENDOR" in
            intel)
                acceleration="intel"
                ;;
            amd)
                acceleration="amd"
                ;;
            nvidia)
                acceleration="nvidia"
                ;;
            *)
                acceleration="software"
                ;;
        esac
    fi

    case "$acceleration" in

        software)

            cat > "$COMPOSE_FILE" <<EOF
services:

  jellyfin:
    image: $JELLYFIN_IMAGE
    container_name: $JELLYFIN_CONTAINER

    ports:
      - "$JELLYFIN_PORT:8096"

    environment:
      - TZ=$timezone

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro

    restart: unless-stopped

    stop_grace_period: 30s
EOF

            HARDWARE_ACCELERATION="software"

            success "Software (CPU) acceleration configured."
            ;;

        intel)

            detect_gpu

            if [[ "$GPU_VENDOR" != "intel" ]]; then
                warning "Intel GPU was not detected."

                if ! confirm "Configure Intel Quick Sync anyway?"; then
                    HARDWARE_ACCELERATION="software"
                    write_compose
                    return
                fi
            fi

            if [[ -z "$GPU_DEVICE" ||
                  -z "$GPU_GID" ]]; then

                error "No usable Intel DRI device was found."
                HARDWARE_ACCELERATION="software"
                write_compose
                return
            fi

            cat > "$COMPOSE_FILE" <<EOF
services:

  jellyfin:
    image: $JELLYFIN_IMAGE
    container_name: $JELLYFIN_CONTAINER

    ports:
      - "$JELLYFIN_PORT:8096"

    environment:
      - TZ=$timezone

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro

    devices:
      - $GPU_DEVICE:$GPU_DEVICE

    group_add:
      - "$GPU_GID"

    restart: unless-stopped

    stop_grace_period: 30s
EOF

            HARDWARE_ACCELERATION="intel"

            success "Intel Quick Sync / VA-API configured."
            ;;

        amd)

            detect_gpu

            if [[ "$GPU_VENDOR" != "amd" ]]; then
                warning "AMD GPU was not detected."

                if ! confirm "Configure AMD VA-API anyway?"; then
                    HARDWARE_ACCELERATION="software"
                    write_compose
                    return
                fi
            fi

            if [[ -z "$GPU_DEVICE" ||
                  -z "$GPU_GID" ]]; then

                error "No usable AMD DRI device was found."
                HARDWARE_ACCELERATION="software"
                write_compose
                return
            fi

            cat > "$COMPOSE_FILE" <<EOF
services:

  jellyfin:
    image: $JELLYFIN_IMAGE
    container_name: $JELLYFIN_CONTAINER

    ports:
      - "$JELLYFIN_PORT:8096"

    environment:
      - TZ=$timezone

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro

    devices:
      - $GPU_DEVICE:$GPU_DEVICE

    group_add:
      - "$GPU_GID"

    restart: unless-stopped

    stop_grace_period: 30s
EOF

            HARDWARE_ACCELERATION="amd"

            success "AMD VA-API configured."
            ;;

        nvidia)

            detect_gpu

            if [[ "$GPU_VENDOR" != "nvidia" ]]; then
                warning "NVIDIA GPU was not detected."

                if ! confirm "Configure NVIDIA anyway?"; then
                    HARDWARE_ACCELERATION="software"
                    write_compose
                    return
                fi
            fi

            if ! check_nvidia_toolkit; then

                warning "NVIDIA Container Toolkit is not installed."

                if confirm "Install NVIDIA Container Toolkit now?"; then
                    install_nvidia_toolkit || {
                        error "Could not configure NVIDIA."
                        HARDWARE_ACCELERATION="software"
                        write_compose
                        return
                    }
                else
                    HARDWARE_ACCELERATION="software"
                    write_compose
                    return
                fi
            fi

            cat > "$COMPOSE_FILE" <<EOF
services:

  jellyfin:
    image: $JELLYFIN_IMAGE
    container_name: $JELLYFIN_CONTAINER

    ports:
      - "$JELLYFIN_PORT:8096"

    environment:
      - TZ=$timezone
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,video,utility

    volumes:
      - ./config:/config
      - ./cache:/cache
      - $MEDIA_MOUNT:/media:ro

    gpus: all

    restart: unless-stopped

    stop_grace_period: 30s
EOF

            HARDWARE_ACCELERATION="nvidia"

            success "NVIDIA NVENC / NVDEC configured."
            ;;

        *)
            HARDWARE_ACCELERATION="software"
            write_compose
            ;;

    esac
}

validate_compose() {
    if ! compose config >/dev/null; then
        error "Docker Compose configuration is invalid."
        return 1
    fi

    success "Docker Compose configuration is valid."
}

apply_hardware_acceleration() {
    header

    echo -e "${BOLD}Hardware Acceleration${RESET}"
    echo

    info "Selected: $(hardware_acceleration_name)"
    echo

    if [[ "$HARDWARE_ACCELERATION" == "nvidia" ]]; then
        detect_gpu

        if [[ "$GPU_VENDOR" == "nvidia" ]]; then
            if ! check_nvidia_toolkit; then
                if confirm "Install NVIDIA Container Toolkit?"; then
                    install_nvidia_toolkit || return 1
                else
                    HARDWARE_ACCELERATION="software"
                fi
            fi
        fi
    fi

    write_compose

    validate_compose || return 1

    echo

    if [[ -f "$COMPOSE_FILE" ]]; then
        if confirm "Recreate Jellyfin container now?"; then

            if ! check_media; then
                warning "Media drive is not mounted."
                warning "Container was not restarted."
                return 0
            fi

            compose up -d --force-recreate || return 1

            success "Jellyfin recreated."

        else

            warning "Configuration saved."
            warning "Recreate Jellyfin later to apply the change."

        fi
    fi
}

# ============================================================
# Installation
# ============================================================

install_jellyfin() {
    header

    echo -e "${BOLD}Install Jellyfin${RESET}"
    echo

    check_supported_system || return 1
    check_dependencies || return 1
    ensure_docker || return 1

    prepare_directories

    # --------------------------------------------------------
    # Media
    # --------------------------------------------------------

    if check_media_fstab; then

        info "Existing media configuration found."

        if is_media_mounted; then
            success "Media drive is already mounted."
        else
            mount_media || return 1
        fi

    else

        info "No media drive configured."

        configure_media || return 1

    fi

    check_media || return 1

    # --------------------------------------------------------
    # Hardware acceleration
    # --------------------------------------------------------

    echo
    echo -e "${BOLD}Hardware Acceleration${RESET}"
    echo
    echo "Hardware acceleration is optional."
    echo
    echo "  1) Software (CPU)"
    echo "  2) Auto Detect GPU"
    echo "  3) Intel Quick Sync"
    echo "  4) AMD VA-API"
    echo "  5) NVIDIA NVENC / NVDEC"
    echo

    read -r -p "Select an option [1]: " choice

    [[ -z "$choice" ]] && choice="1"

    case "$choice" in
        1)
            HARDWARE_ACCELERATION="software"
            ;;
        2)
            HARDWARE_ACCELERATION="auto"
            ;;
        3)
            HARDWARE_ACCELERATION="intel"
            ;;
        4)
            HARDWARE_ACCELERATION="amd"
            ;;
        5)
            HARDWARE_ACCELERATION="nvidia"
            ;;
        *)
            warning "Invalid option. Using Software (CPU)."
            HARDWARE_ACCELERATION="software"
            ;;
    esac

    # --------------------------------------------------------
    # Compose
    # --------------------------------------------------------

    write_compose

    validate_compose || return 1

    # --------------------------------------------------------
    # Pull
    # --------------------------------------------------------

    echo
    info "Pulling Jellyfin image..."

    compose pull || return 1

    success "Jellyfin image downloaded."

    # --------------------------------------------------------
    # Start
    # --------------------------------------------------------

    start_jellyfin || return 1

    echo
    success "Jellyfin installation completed."

    echo
    echo "Jellyfin:"
    echo
    echo "  http://SERVER_IP:$JELLYFIN_PORT"
    echo

    echo "Hardware acceleration:"
    echo "  $(hardware_acceleration_name)"
    echo

    echo "Media:"
    echo "  /media"
    echo

    echo "Create Movies, TV Shows and other libraries"
    echo "from the Jellyfin web interface."
}

# ============================================================
# Start / Stop / Restart
# ============================================================

start_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    if ! check_media; then
        warning "Jellyfin will not start without the media drive."
        return 1
    fi

    info "Starting Jellyfin..."

    if compose up -d; then
        success "Jellyfin started."
    else
        error "Failed to start Jellyfin."
        return 1
    fi
}

stop_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    info "Stopping Jellyfin..."

    if compose stop; then
        success "Jellyfin stopped."
    else
        error "Failed to stop Jellyfin."
        return 1
    fi
}

restart_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    if ! check_media; then
        warning "Jellyfin will not restart without the media drive."
        return 1
    fi

    info "Restarting Jellyfin..."

    if compose restart; then
        success "Jellyfin restarted."
    else
        error "Failed to restart Jellyfin."
        return 1
    fi
}

# ============================================================
# Update
# ============================================================

update_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    info "Pulling latest Jellyfin image..."

    compose pull || return 1

    success "Latest Jellyfin image downloaded."

    if ! check_media; then
        warning "Media drive is not mounted."
        warning "Jellyfin will not be started."
        return 1
    fi

    info "Recreating Jellyfin..."

    compose up -d || return 1

    success "Jellyfin updated."
}

recreate_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    if ! check_media; then
        warning "Media drive is not mounted."
        return 1
    fi

    info "Recreating Jellyfin container..."

    compose up -d --force-recreate || return 1

    success "Jellyfin container recreated."
}

# ============================================================
# Status
# ============================================================

status_jellyfin() {
    header

    echo -e "${BOLD}Jellyfin Status${RESET}"
    echo

    echo "Project:"
    echo "  $JELLYFIN_DIR"
    echo

    echo "Media:"
    echo "  $MEDIA_MOUNT"
    echo

    if is_media_mounted; then

        success "Media drive: mounted"

        echo
        echo "  Device : $(get_media_device)"
        echo "  UUID   : $(get_media_uuid)"
        echo "  FS     : $(get_media_filesystem)"

    else

        warning "Media drive: not mounted"

    fi

    echo

    echo "Hardware acceleration:"
    echo "  $(hardware_acceleration_name)"

    echo

    if [[ ! -f "$COMPOSE_FILE" ]]; then
        warning "Jellyfin is not installed."
        return 0
    fi

    compose ps

    echo

    if container_running; then
        success "Jellyfin: running"
    elif container_exists; then
        warning "Jellyfin: stopped"
    else
        warning "Jellyfin: container not created"
    fi
}

# ============================================================
# Logs
# ============================================================

logs_jellyfin() {
    check_jellyfin || return 1
    ensure_docker || return 1

    header

    echo -e "${BOLD}Jellyfin Logs${RESET}"
    echo
    echo "Press Ctrl+C to exit."
    echo

    compose logs -f --tail=100
}

# ============================================================
# Backup
# ============================================================

backup_jellyfin() {
    check_jellyfin || return 1

    mkdir -p "$BACKUP_DIR"

    local timestamp
    local backup_file
    local was_running=false

    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_file="$BACKUP_DIR/jellyfin-backup-$timestamp.tar.gz"

    echo
    info "Creating Jellyfin backup..."

    if container_running; then
        was_running=true

        info "Stopping Jellyfin..."

        compose stop || return 1
    fi

    info "Backing up Jellyfin configuration..."

    if tar \
        -czf "$backup_file" \
        -C "$SCRIPT_DIR" \
        "jellyfin/config" \
        "jellyfin/docker-compose.yml"; then

        success "Backup created."

    else

        error "Backup failed."

        if [[ "$was_running" == true ]]; then
            compose up -d >/dev/null 2>&1 || true
        fi

        return 1
    fi

    if [[ "$was_running" == true ]]; then

        if check_media; then
            info "Starting Jellyfin again..."
            compose up -d >/dev/null 2>&1 || true
        fi

    fi

    echo
    echo "Backup:"
    echo "  $backup_file"
    echo

    echo "Size:"
    echo "  $(du -h "$backup_file" | cut -f1)"
    echo

    info "Media files were not included."
}

list_backups() {
    mkdir -p "$BACKUP_DIR"

    echo
    echo "Available backups:"
    echo

    shopt -s nullglob

    local backups=(
        "$BACKUP_DIR"/jellyfin-backup-*.tar.gz
    )

    shopt -u nullglob

    if [[ ${#backups[@]} -eq 0 ]]; then
        warning "No backups found."
        return 0
    fi

    local backup

    for backup in "${backups[@]}"; do
        printf "  %-45s %s\n" \
            "$(basename "$backup")" \
            "$(du -h "$backup" | cut -f1)"
    done
}

restore_jellyfin() {
    mkdir -p "$BACKUP_DIR"

    header

    echo -e "${BOLD}Restore Jellyfin Backup${RESET}"
    echo

    list_backups

    echo

    read -r -p "Backup filename: " backup_name

    [[ -n "$backup_name" ]] || {
        error "No backup selected."
        return 1
    }

    local backup_file

    if [[ "$backup_name" = /* ]]; then
        backup_file="$backup_name"
    else
        backup_file="$BACKUP_DIR/$backup_name"
    fi

    [[ -f "$backup_file" ]] || {
        error "Backup file not found:"
        echo "  $backup_file"
        return 1
    }

    echo
    warning "The current Jellyfin configuration will be replaced."
    warning "Your media files will NOT be touched."
    echo

    confirm "Continue with restore?" || {
        warning "Restore cancelled."
        return 1
    }

    if [[ -d "$CONFIG_DIR" ]]; then

        local safety_backup

        safety_backup="$BACKUP_DIR/jellyfin-before-restore-$(date +%Y%m%d-%H%M%S).tar.gz"

        info "Creating safety backup..."

        tar \
            -czf "$safety_backup" \
            -C "$SCRIPT_DIR" \
            "jellyfin/config" \
            "jellyfin/docker-compose.yml" \
            2>/dev/null || true

        success "Safety backup created."

    fi

    if container_running; then
        info "Stopping Jellyfin..."
        compose stop || return 1
    fi

    info "Restoring configuration..."

    rm -rf "$CONFIG_DIR"

    if ! tar \
        -xzf "$backup_file" \
        -C "$SCRIPT_DIR"; then

        error "Restore failed."
        return 1
    fi

    success "Configuration restored."

    if check_media; then

        info "Starting restored Jellyfin..."

        compose up -d || return 1

        success "Jellyfin restored and started."

    else

        warning "Media drive is not mounted."
        warning "Jellyfin was restored but not started."

    fi
}

# ============================================================
# Hardware menu
# ============================================================

hardware_menu() {
    select_hardware_acceleration
}

# ============================================================
# Media menu
# ============================================================

media_menu() {
    while true; do

        header

        echo -e "${BOLD}Media Storage${RESET}"
        echo

        if is_media_mounted; then

            success "Media drive: mounted"

            echo
            echo "Device : $(get_media_device)"
            echo "UUID   : $(get_media_uuid)"
            echo "FS     : $(get_media_filesystem)"

        else

            warning "Media drive: not mounted"

        fi

        echo
        echo "  1) Configure Media Drive"
        echo "  2) Mount Media Drive"
        echo "  3) Unmount Media Drive"
        echo "  4) Show Disk Information"
        echo "  0) Back"
        echo

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                configure_media
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
                show_disks
                pause
                ;;

            0)
                return 0
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Backup menu
# ============================================================

backup_menu() {
    while true; do

        header

        echo -e "${BOLD}Backup & Restore${RESET}"
        echo

        echo "Backup directory:"
        echo "  $BACKUP_DIR"
        echo

        echo "  1) Create Backup"
        echo "  2) Restore Backup"
        echo "  3) List Backups"
        echo "  0) Back"
        echo

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                backup_jellyfin
                pause
                ;;

            2)
                restore_jellyfin
                pause
                ;;

            3)
                list_backups
                pause
                ;;

            0)
                return 0
                ;;

            *)
                warning "Invalid option."
                sleep 1
                ;;

        esac

    done
}

# ============================================================
# Configuration
# ============================================================

show_configuration() {
    header

    echo -e "${BOLD}Configuration${RESET}"
    echo

    echo "Script directory:"
    echo "  $SCRIPT_DIR"
    echo

    echo "Jellyfin directory:"
    echo "  $JELLYFIN_DIR"
    echo

    echo "Config:"
    echo "  $CONFIG_DIR"
    echo

    echo "Cache:"
    echo "  $CACHE_DIR"
    echo

    echo "Backups:"
    echo "  $BACKUP_DIR"
    echo

    echo "Media:"
    echo "  $MEDIA_MOUNT"
    echo

    echo "Port:"
    echo "  $JELLYFIN_PORT"
    echo

    echo "Timezone:"
    echo "  $(get_timezone)"
    echo

    echo "Hardware acceleration:"
    echo "  $(hardware_acceleration_name)"
    echo

    echo "Image:"
    echo "  $JELLYFIN_IMAGE"
    echo

    echo "────────────────────────────────────────"
    echo

    if [[ -f "$COMPOSE_FILE" ]]; then
        cat "$COMPOSE_FILE"
    else
        warning "docker-compose.yml does not exist."
    fi

    echo

    pause
}

# ============================================================
# Remove
# ============================================================

remove_jellyfin() {
    check_jellyfin || return 1

    header

    echo -e "${BOLD}Remove Jellyfin${RESET}"
    echo

    warning "This will remove:"
    echo
    echo "  - Jellyfin container"
    echo "  - Jellyfin configuration"
    echo "  - Jellyfin cache"
    echo "  - Docker Compose project"
    echo

    echo "It will NOT remove:"
    echo
    echo "  - Your media files"
    echo "  - Your media disk"
    echo "  - The /etc/fstab mount configuration"
    echo

    confirm "Remove Jellyfin?" || {
        warning "Operation cancelled."
        return 1
    }

    if confirm "Create a backup before removing Jellyfin?"; then
        backup_jellyfin || true
    fi

    info "Stopping and removing Jellyfin..."

    compose down || true

    info "Removing Jellyfin directory..."

    rm -rf "$JELLYFIN_DIR"

    success "Jellyfin removed."

    echo
    warning "Your media files were not touched."
}

# ============================================================
# Main menu
# ============================================================

main_menu() {
    while true; do

        header

        echo "Project:"
        echo "  $JELLYFIN_DIR"
        echo

        if [[ ! -f "$COMPOSE_FILE" ]]; then

            echo -e "Jellyfin: ${YELLOW}Not installed${RESET}"

        elif container_running; then

            echo -e "Jellyfin: ${GREEN}Running${RESET}"

        elif container_exists; then

            echo -e "Jellyfin: ${YELLOW}Stopped${RESET}"

        else

            echo -e "Jellyfin: ${YELLOW}Not started${RESET}"

        fi

        if is_media_mounted; then
            echo -e "Media:    ${GREEN}Mounted${RESET}"
        else
            echo -e "Media:    ${YELLOW}Not mounted${RESET}"
        fi

        echo -e "Hardware: $(hardware_acceleration_name)"

        echo
        echo "────────────────────────────────────────"
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
        echo " 12) Configuration"
        echo
        echo " 13) Remove Jellyfin"
        echo
        echo "  0) Exit"
        echo

        read -r -p "Select an option: " choice

        case "$choice" in

            1)
                install_jellyfin
                pause
                ;;

            2)
                start_jellyfin
                pause
                ;;

            3)
                stop_jellyfin
                pause
                ;;

            4)
                restart_jellyfin
                pause
                ;;

            5)
                update_jellyfin
                pause
                ;;

            6)
                recreate_jellyfin
                pause
                ;;

            7)
                status_jellyfin
                pause
                ;;

            8)
                logs_jellyfin
                ;;

            9)
                media_menu
                ;;

            10)
                hardware_menu
                ;;

            11)
                backup_menu
                ;;

            12)
                show_configuration
                ;;

            13)
                remove_jellyfin
                pause
                ;;

            0)
                echo
                echo "Goodbye."
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

main_menu
