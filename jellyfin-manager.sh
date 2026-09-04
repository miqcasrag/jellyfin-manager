#!/usr/bin/env bash

set -o pipefail

# ============================================================
# Jellyfin Manager
# ============================================================

SCRIPT_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JELLYFIN_DIR="$SCRIPT_DIR/jellyfin"
BACKUP_DIR="$SCRIPT_DIR/backups"

COMPOSE_FILE="$JELLYFIN_DIR/docker-compose.yml"
ENV_FILE="$JELLYFIN_DIR/.env"

JELLYFIN_IMAGE="jellyfin/jellyfin:latest"

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

            error "Docker is installed, but this user cannot access it."
            echo
            info "Run:"
            echo
            echo "  sudo usermod -aG docker \$USER"
            echo "  newgrp docker"
            echo
            warning "You can also log out and log back in."
            echo

        else

            error "Docker daemon is not running or is not reachable."
            info "Try: sudo systemctl start docker"

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

    local missing=0

    if ! command -v git >/dev/null 2>&1; then
        missing=1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        missing=1
    fi

    if command -v docker >/dev/null 2>&1 &&
       ! docker compose version >/dev/null 2>&1; then
        missing=1
    fi

    if [[ "$missing" -eq 0 ]]; then
        success "Dependencies ready."
        return 0
    fi

    info "Installing dependencies..."
    echo

    if ! command -v apt >/dev/null 2>&1; then
        error "This installer requires a Debian-based system with apt."
        return 1
    fi

    sudo apt update

    if ! command -v git >/dev/null 2>&1; then
        sudo apt install -y git
    fi

    if ! command -v docker >/dev/null 2>&1; then

        info "Installing Docker..."

        sudo apt install -y \
            ca-certificates \
            curl

        sudo install \
            -m 0755 \
            -d \
            /etc/apt/keyrings

        if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then

            sudo curl -fsSL \
                https://download.docker.com/linux/debian/gpg \
                -o /etc/apt/keyrings/docker.asc

            sudo chmod a+r \
                /etc/apt/keyrings/docker.asc

        fi

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian \
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

        sudo systemctl enable --now docker

        sudo usermod -aG docker "$USER"

        warning "Your user was added to the docker group."
        warning "Log out and back in, or run: newgrp docker"

        if ! docker info >/dev/null 2>&1; then
            echo
            warning "Docker is installed, but the current shell cannot access it yet."
            warning "Run this script again after reloading your session."
            return 1
        fi

    fi

    if ! docker compose version >/dev/null 2>&1; then

        info "Installing Docker Compose..."

        sudo apt install -y docker-compose-plugin

    fi

    if ! docker compose version >/dev/null 2>&1; then
        error "Docker Compose installation failed."
        return 1
    fi

    success "Dependencies ready."

    return 0
}

# ============================================================
# Directory setup
# ============================================================

prepare_directories() {

    mkdir -p \
        "$JELLYFIN_DIR/config" \
        "$JELLYFIN_DIR/cache" \
        "$JELLYFIN_DIR/transcodes" \
        "$BACKUP_DIR"

    success "Jellyfin directories ready."
}

# ============================================================
# Docker Compose
# ============================================================

create_compose_file() {

    mkdir -p "$JELLYFIN_DIR"

    cat > "$COMPOSE_FILE" << 'EOF'
services:

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped

    ports:
      - "8096:8096"
      - "8920:8920"

    environment:
      - TZ=${TZ}

    volumes:
      - ./config:/config
      - ./cache:/cache
      - ./transcodes:/transcodes
      - ${MEDIA_PATH}:/media:ro

EOF

    success "Docker Compose configuration created."
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

configure_timezone() {

    local timezone

    timezone="$(get_timezone)"

    touch "$ENV_FILE"

    if grep -q '^TZ=' "$ENV_FILE"; then

        sed -i \
            "s|^TZ=.*$|TZ=$timezone|" \
            "$ENV_FILE"

    else

        echo "TZ=$timezone" >> "$ENV_FILE"

    fi

    success "Timezone: $timezone"
}

# ============================================================
# Media Storage
# ============================================================

get_media_path() {

    if [[ -f "$ENV_FILE" ]]; then

        local path

        path="$(
            grep '^MEDIA_PATH=' "$ENV_FILE" |
            head -n 1 |
            cut -d '=' -f2-
        )"

        if [[ -n "$path" ]]; then
            echo "$path"
            return 0
        fi

    fi

    echo ""
}

save_media_path() {

    local path="$1"

    touch "$ENV_FILE"

    if grep -q '^MEDIA_PATH=' "$ENV_FILE"; then

        sed -i \
            "s|^MEDIA_PATH=.*$|MEDIA_PATH=$path|" \
            "$ENV_FILE"

    else

        echo "MEDIA_PATH=$path" >> "$ENV_FILE"

    fi
}

list_storage_devices() {

    echo
    echo "Available storage devices:"
    echo

    lsblk \
        -o NAME,TYPE,FSTYPE,LABEL,UUID,SIZE,MOUNTPOINTS \
        -e 7,11

    echo
}

get_partition_uuid() {

    local device="$1"

    blkid -s UUID -o value "$device" 2>/dev/null
}

get_partition_label() {

    local device="$1"

    blkid -s LABEL -o value "$device" 2>/dev/null
}

get_mountpoint() {

    local device="$1"

    findmnt \
        -n \
        -o TARGET \
        "$device" \
        2>/dev/null |
    head -n 1
}

select_storage_device() {

    local devices=()
    local device
    local choice
    local index

    while IFS= read -r device; do
        [[ -n "$device" ]] && devices+=("$device")
    done < <(
        lsblk \
            -nrpo NAME,TYPE |
        awk '$2 == "part" {print $1}'
    )

    if [[ ${#devices[@]} -eq 0 ]]; then

        error "No partitions were found."
        return 1

    fi

    echo
    echo "Select the media partition:"
    echo

    local i=1

    for device in "${devices[@]}"; do

        local filesystem
        local label
        local uuid
        local size
        local mountpoint

        filesystem="$(blkid -s TYPE -o value "$device" 2>/dev/null)"
        label="$(get_partition_label "$device")"
        uuid="$(get_partition_uuid "$device")"
        size="$(lsblk -dnro SIZE "$device" 2>/dev/null)"
        mountpoint="$(get_mountpoint "$device")"

        printf "  %2d  %-18s %-8s %-20s %-38s %-12s" \
            "$i" \
            "$device" \
            "${filesystem:-unknown}" \
            "${label:-no-label}" \
            "${uuid:-no-uuid}" \
            "${size:-unknown}"

        if [[ -n "$mountpoint" ]]; then
            printf " %s" "$mountpoint"
        fi

        echo

        i=$((i + 1))

    done

    echo
    echo "  0  Back"
    echo

    read -r -p "Select partition: " choice

    [[ "$choice" == "0" ]] && return 1

    if ! [[ "$choice" =~ ^[0-9]+$ ]]; then

        error "Invalid selection."
        return 1

    fi

    index=$((choice - 1))

    if (( index < 0 || index >= ${#devices[@]} )); then

        error "Invalid selection."
        return 1

    fi

    SELECTED_DEVICE="${devices[$index]}"

    return 0
}

create_mount_directory() {

    local mountpoint="$1"

    if [[ ! -d "$mountpoint" ]]; then

        info "Creating mount point:"
        echo "  $mountpoint"
        echo

        if ! sudo mkdir -p "$mountpoint"; then
            error "Could not create mount point."
            return 1
        fi

    fi

    return 0
}

configure_fstab_mount() {

    local device="$1"
    local uuid
    local filesystem
    local label
    local mountpoint

    uuid="$(get_partition_uuid "$device")"
    filesystem="$(blkid -s TYPE -o value "$device" 2>/dev/null)"
    label="$(get_partition_label "$device")"

    if [[ -z "$uuid" ]]; then

        error "Could not determine partition UUID."
        echo
        info "Device: $device"
        echo

        blkid "$device" 2>/dev/null || true

        return 1
    fi

    if [[ "$filesystem" != "exfat" &&
          "$filesystem" != "ext4" &&
          "$filesystem" != "ntfs" &&
          "$filesystem" != "vfat" &&
          "$filesystem" != "xfs" &&
          "$filesystem" != "btrfs" ]]; then

        warning "Filesystem detected: ${filesystem:-unknown}"
        warning "This filesystem may require additional mount options."

    fi

    mountpoint="/mnt/jellyfin-media"

    if [[ -n "$label" ]]; then

        local safe_label

        safe_label="$(
            echo "$label" |
            tr '[:space:]' '_' |
            tr -cd '[:alnum:]_.-'
        )"

        if [[ -n "$safe_label" ]]; then
            mountpoint="/mnt/$safe_label"
        fi

    fi

    create_mount_directory "$mountpoint" || return 1

    echo
    info "Partition:"
    echo "  Device:      $device"
    echo "  Filesystem:  ${filesystem:-unknown}"
    echo "  Label:       ${label:-none}"
    echo "  UUID:        $uuid"
    echo "  Mount point: $mountpoint"
    echo

    if ! confirm "Configure this partition to mount automatically?"; then
        return 1
    fi

    local fstab_line

    case "$filesystem" in

        exfat)
            fstab_line="UUID=$uuid $mountpoint exfat defaults,nofail,x-systemd.automount 0 0"
            ;;

        ntfs|ntfs3)
            fstab_line="UUID=$uuid $mountpoint ntfs3 defaults,nofail,x-systemd.automount 0 0"
            ;;

        vfat)
            fstab_line="UUID=$uuid $mountpoint vfat defaults,nofail,x-systemd.automount 0 0"
            ;;

        *)
            fstab_line="UUID=$uuid $mountpoint $filesystem defaults,nofail,x-systemd.automount 0 0"
            ;;

    esac

    echo
    info "Adding mount to /etc/fstab..."

    if grep -qE "^[[:space:]]*UUID=$uuid[[:space:]]" /etc/fstab 2>/dev/null; then

        warning "An /etc/fstab entry for this UUID already exists."

    else

        echo "$fstab_line" |
            sudo tee -a /etc/fstab >/dev/null

        if [[ $? -ne 0 ]]; then

            error "Could not update /etc/fstab."
            return 1

        fi

        success "Automatic mount configured."

    fi

    if ! sudo mountpoint -q "$mountpoint"; then

        info "Mounting media storage..."

        if ! sudo mount "$mountpoint"; then

            warning "Mount failed."
            warning "The fstab entry was created, but the disk could not be mounted now."
            return 1

        fi

    fi

    if ! mountpoint -q "$mountpoint"; then

        warning "Mount point is not active."
        return 1

    fi

    success "Media storage mounted."
    echo
    echo "  $mountpoint"

    save_media_path "$mountpoint"

    success "Jellyfin media path saved."

    return 0
}

media_storage_status() {

    header

    echo "Media Storage"
    echo "────────────────────────────────────────"
    echo

    local media_path

    media_path="$(get_media_path)"

    if [[ -z "$media_path" ]]; then

        warning "No media storage configured."

    else

        echo "Configured path:"
        echo
        echo "  $media_path"
        echo

        if mountpoint -q "$media_path"; then

            success "Media storage is mounted."

            echo

            df -h "$media_path" 2>/dev/null || true

        else

            error "Media storage is NOT mounted."
            warning "Jellyfin will not be able to access the media."

        fi

    fi

    echo
    echo "Mounted filesystems:"
    echo

    findmnt \
        -t ext4,exfat,ntfs,ntfs3,xfs,btrfs,vfat \
        2>/dev/null |
    head -n 30

    pause
}

configure_media_storage() {

    header

    echo "Media Storage"
    echo "────────────────────────────────────────"
    echo

    local current

    current="$(get_media_path)"

    if [[ -n "$current" ]]; then

        echo "Current media path:"
        echo
        echo "  $current"
        echo

        if mountpoint -q "$current"; then
            success "Currently mounted."
        else
            warning "Currently NOT mounted."
        fi

        echo

    fi

    echo "  1  Select storage partition"
    echo "  2  Enter existing mount path"
    echo "  3  Check storage status"
    echo "  0  Back"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            list_storage_devices

            if select_storage_device; then

                echo

                configure_fstab_mount "$SELECTED_DEVICE"

            fi

            pause
            ;;

        2)

            echo
            read -r -p "Enter media mount path: " path

            if [[ -z "$path" ]]; then

                error "Path cannot be empty."

            elif [[ ! -d "$path" ]]; then

                error "Directory does not exist."
                echo
                info "Create or mount the disk first."

            else

                save_media_path "$path"

                success "Media path saved:"
                echo "  $path"

            fi

            pause
            ;;

        3)

            media_storage_status
            ;;

        0)
            return
            ;;

        *)
            error "Invalid selection."
            pause
            ;;

    esac
}

# ============================================================
# Hardware Acceleration
# ============================================================

get_hwaccel() {

    if [[ -f "$ENV_FILE" ]]; then

        grep '^HW_ACCEL=' "$ENV_FILE" |
            head -n 1 |
            cut -d '=' -f2-

    fi
}

save_hwaccel() {

    local value="$1"

    touch "$ENV_FILE"

    if grep -q '^HW_ACCEL=' "$ENV_FILE"; then

        sed -i \
            "s|^HW_ACCEL=.*$|HW_ACCEL=$value|" \
            "$ENV_FILE"

    else

        echo "HW_ACCEL=$value" >> "$ENV_FILE"

    fi
}

get_render_node() {

    local node

    for node in /dev/dri/renderD1* /dev/dri/card*; do
        [[ -e "$node" ]] && echo "$node" && return 0
    done

    return 1
}

get_gpu_vendor_id() {

    # Reads the PCI vendor ID behind a /dev/dri node (e.g. 0x8086 = Intel,
    # 0x1002/0x1022 = AMD, 0x10de = NVIDIA). This is what actually tells GPUs
    # apart; the mere presence of /dev/dri does not.
    local node="$1"
    local name
    local vendor_file

    [[ -z "$node" ]] && return 1

    name="$(basename "$node")"
    vendor_file="/sys/class/drm/$name/device/vendor"

    if [[ -r "$vendor_file" ]]; then
        cat "$vendor_file" 2>/dev/null
        return 0
    fi

    return 1
}

check_intel_gpu() {

    local node vendor

    node="$(get_render_node)" || return 1
    vendor="$(get_gpu_vendor_id "$node")"

    [[ "$vendor" == "0x8086" ]]
}

check_amd_gpu() {

    local node vendor

    node="$(get_render_node)" || return 1
    vendor="$(get_gpu_vendor_id "$node")"

    [[ "$vendor" == "0x1002" ]] || [[ "$vendor" == "0x1022" ]]
}

check_nvidia_gpu() {

    command -v nvidia-smi >/dev/null 2>&1 &&
    nvidia-smi >/dev/null 2>&1
}

get_render_group_gid() {

    # The container needs to belong to whichever host group owns the render
    # node, or it gets "Permission denied" against /dev/dri and Jellyfin
    # silently falls back to software (libx264) transcoding.
    local node="$1"
    local gid

    if [[ -n "$node" ]] && [[ -e "$node" ]]; then

        gid="$(stat -c '%g' "$node" 2>/dev/null)"

        if [[ -n "$gid" ]] && [[ "$gid" != "0" ]]; then
            echo "$gid"
            return 0
        fi

    fi

    gid="$(getent group render 2>/dev/null | cut -d: -f3)"
    [[ -n "$gid" ]] && echo "$gid" && return 0

    gid="$(getent group video 2>/dev/null | cut -d: -f3)"
    [[ -n "$gid" ]] && echo "$gid" && return 0

    return 1
}

detect_hwaccel() {

    # Best-effort automatic pick, in priority order.
    if check_nvidia_gpu; then
        echo "nvidia"
    elif check_intel_gpu; then
        echo "qsv"
    elif check_amd_gpu; then
        echo "vaapi"
    else
        echo "none"
    fi
}

hardware_acceleration_status() {

    echo
    echo "Hardware detection:"
    echo

    local node
    node="$(get_render_node)"

    if [[ -n "$node" ]]; then

        if check_intel_gpu; then
            success "Intel GPU detected ($node) → Quick Sync (QSV)."
        elif check_amd_gpu; then
            success "AMD GPU detected ($node) → VA-API."
        else
            warning "GPU device found ($node) but vendor could not be identified."
        fi

    else

        warning "No /dev/dri GPU device detected."

    fi

    if check_nvidia_gpu; then

        success "NVIDIA GPU detected."

        nvidia-smi \
            --query-gpu=name,driver_version \
            --format=csv,noheader \
            2>/dev/null || true

    else

        info "NVIDIA GPU not detected."

    fi

    echo

    if [[ -n "$node" ]]; then

        info "Available DRM devices:"
        ls -l /dev/dri 2>/dev/null

        local gid
        gid="$(get_render_group_gid "$node")"

        if [[ -n "$gid" ]]; then
            info "Render group GID on host: $gid (needed inside the container too)."
        else
            warning "Could not determine the render/video group GID."
        fi

    fi

    echo
}

create_hardware_compose_override() {

    local hwaccel="$1"
    local override="$JELLYFIN_DIR/docker-compose.override.yml"

    rm -f "$override"

    case "$hwaccel" in

        none)

            success "Hardware acceleration disabled."
            ;;

        qsv|vaapi)

            if [[ ! -d /dev/dri ]]; then

                error "No /dev/dri device found."
                warning "Hardware transcoding requires a supported GPU and /dev/dri."
                return 1

            fi

            local node gid
            node="$(get_render_node)"
            gid="$(get_render_group_gid "$node")"

            {
                echo "services:"
                echo
                echo "  jellyfin:"
                echo "    devices:"
                echo "      - /dev/dri:/dev/dri"

                if [[ -n "$gid" ]]; then
                    echo "    group_add:"
                    echo "      - \"$gid\""
                else
                    warning "Could not detect the render group GID automatically."
                    warning "If transcoding fails with a permission error, add it manually:"
                    echo "  group_add: [\"<GID of getent group render>\"]"
                fi
            } > "$override"

            if [[ "$hwaccel" == "qsv" ]]; then
                success "Intel Quick Sync (QSV) device + group configured."
            else
                success "AMD VA-API device + group configured."
            fi

            warning "You still need to enable it in Jellyfin: Dashboard → Playback →"
            warning "Hardware acceleration → pick this method, enable hardware"
            warning "decoding/encoding, and disable both 'low-power' options."
            ;;

        nvidia)

            if ! check_nvidia_gpu; then

                error "nvidia-smi was not found."
                warning "Install the NVIDIA driver and NVIDIA Container Toolkit first."
                return 1

            fi

            cat > "$override" << 'EOF'
services:

  jellyfin:
    gpus: all
EOF

            success "NVIDIA GPU configured."
            ;;

        *)

            error "Unknown hardware acceleration mode."
            return 1
            ;;

    esac

    return 0
}

configure_hardware_acceleration() {

    header

    echo "Hardware Acceleration"
    echo "────────────────────────────────────────"
    echo

    local current

    current="$(get_hwaccel)"

    if [[ -z "$current" ]]; then
        current="none"
    fi

    echo "Current:"
    echo

    case "$current" in

        qsv)
            echo -e "  ${GREEN}Intel Quick Sync${RESET}"
            ;;

        vaapi)
            echo -e "  ${GREEN}AMD VA-API${RESET}"
            ;;

        nvidia)
            echo -e "  ${GREEN}NVIDIA NVENC/NVDEC${RESET}"
            ;;

        *)
            echo -e "  ${DIM}Disabled${RESET}"
            ;;

    esac

    echo

    hardware_acceleration_status

    echo
    local suggested
    suggested="$(detect_hwaccel)"

    echo "Select hardware acceleration:"
    echo
    echo "  1  Disabled"
    echo "  2  Intel Quick Sync"
    echo "  3  AMD VA-API"
    echo "  4  NVIDIA NVENC/NVDEC"
    echo -e "  5  Auto-detect ${DIM}(suggested: $suggested)${RESET}"
    echo "  0  Back"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            save_hwaccel "none"
            create_hardware_compose_override "none"

            ;;

        2)

            if create_hardware_compose_override "qsv"; then
                save_hwaccel "qsv"
            fi

            ;;

        3)

            if create_hardware_compose_override "vaapi"; then
                save_hwaccel "vaapi"
            fi

            ;;

        4)

            if create_hardware_compose_override "nvidia"; then
                save_hwaccel "nvidia"
            fi

            ;;

        5)

            info "Auto-detected: $suggested"

            if create_hardware_compose_override "$suggested"; then
                save_hwaccel "$suggested"
            fi

            ;;

        0)
            return
            ;;

        *)

            error "Invalid selection."

            ;;

    esac

    echo

    if [[ "$choice" != "0" ]]; then

        info "Restart Jellyfin for the change to take effect."

        if confirm "Restart Jellyfin now?"; then

            restart_server

        fi

    fi

    pause
}

# ============================================================
# Hardware Acceleration Diagnostics
# ============================================================

diagnose_hardware_acceleration() {

    header

    echo "Hardware Acceleration Diagnostics"
    echo "────────────────────────────────────────"
    echo

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    local node gid
    node="$(get_render_node)"

    if [[ -z "$node" ]]; then
        error "No /dev/dri device on the host. Hardware transcoding is impossible."
        pause
        return
    fi

    success "Host render device: $node"
    ls -l /dev/dri 2>/dev/null
    echo

    gid="$(get_render_group_gid "$node")"
    [[ -n "$gid" ]] && info "Expected render/video group GID: $gid"

    if ! compose ps --status running --services 2>/dev/null | grep -qx "jellyfin"; then

        warning "Jellyfin container is not running, cannot check inside it."
        pause
        return

    fi

    echo
    echo "Inside the container:"
    echo

    if compose exec -T jellyfin ls -l /dev/dri >/tmp/jf_dri_check 2>&1; then

        cat /tmp/jf_dri_check
        success "The container can see /dev/dri."

    else

        error "The container CANNOT access /dev/dri (permission denied or not passed through)."
        cat /tmp/jf_dri_check 2>/dev/null

    fi

    rm -f /tmp/jf_dri_check

    echo
    info "Groups inside the container:"
    compose exec -T jellyfin id 2>/dev/null || warning "Could not run 'id' inside the container."

    echo
    info "ffmpeg processes currently running inside the container (should normally be idle/empty):"
    echo

    if compose exec -T jellyfin sh -c "ps aux 2>/dev/null | grep '[f]fmpeg'" 2>/dev/null; then

        warning "There is an active ffmpeg process. If this persists for a long time"
        warning "with no one watching anything, it may be a stuck/looping transcode"
        warning "(common when QSV/VAAPI fails and it keeps retrying) - this alone can"
        warning "keep the CPU package power high even though the UI looks idle."

    else

        info "No ffmpeg process running right now."

    fi

    echo
    info "Recent log lines mentioning hardware acceleration errors:"
    echo

    compose logs --tail=300 jellyfin 2>/dev/null |
        grep -iE "vaapi|qsv|quick ?sync|hwaccel|va display|permission denied.*dri" |
        tail -n 20 || true

    echo
    info "Reminder: passing the device is not enough. In Jellyfin's Dashboard →"
    info "Playback, Hardware acceleration must be explicitly set to QSV/VA-API,"
    info "with hardware decoding enabled and both low-power options disabled."

    pause
}

# ============================================================
# Configuration menu
# ============================================================

configuration_menu() {

    while true; do

        header

        echo "Configuration"
        echo "────────────────────────────────────────"
        echo

        echo "  1  Media Storage"
        echo "  2  Hardware Acceleration"
        echo "  3  Hardware Acceleration Diagnostics"
        echo
        echo "  0  Back"
        echo

        local choice

        read -r -p "Select: " choice

        case "$choice" in

            1)
                configure_media_storage
                ;;

            2)
                configure_hardware_acceleration
                ;;

            3)
                diagnose_hardware_acceleration
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
# Status
# ============================================================

status_server() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Jellyfin Status"
    echo "────────────────────────────────────────"
    echo

    local status

    status="$(
        compose ps \
            --format '{{.State}}|{{.Status}}' \
            jellyfin 2>/dev/null |
        head -n 1
    )"

    if [[ -z "$status" ]]; then

        echo -e "Status      ${RED}● OFFLINE${RESET}"

    elif echo "$status" | grep -q '^running|'; then

        echo -e "Status      ${GREEN}● ONLINE${RESET}"

    else

        echo -e "Status      ${RED}● OFFLINE${RESET}"

    fi

    echo

    local media_path

    media_path="$(get_media_path)"

    if [[ -n "$media_path" ]]; then

        if mountpoint -q "$media_path"; then

            echo -e "Media       ${GREEN}● MOUNTED${RESET}"
            echo "Path        $media_path"

        else

            echo -e "Media       ${RED}● NOT MOUNTED${RESET}"
            echo "Path        $media_path"

        fi

    else

        echo -e "Media       ${YELLOW}● NOT CONFIGURED${RESET}"

    fi

    echo

    local hw

    hw="$(get_hwaccel)"

    case "$hw" in

        qsv)
            echo "Hardware    Intel Quick Sync"
            ;;

        vaapi)
            echo "Hardware    AMD VA-API"
            ;;

        nvidia)
            echo "Hardware    NVIDIA NVENC/NVDEC"
            ;;

        *)
            echo "Hardware    Disabled"
            ;;

    esac

    echo

    compose ps 2>/dev/null

    pause
}

# ============================================================
# Start
# ============================================================

start_server() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    echo "Start"
    echo "────────────────────────────────────────"
    echo

    local media_path

    media_path="$(get_media_path)"

    if [[ -z "$media_path" ]]; then

        warning "No media storage is configured."
        echo

        if ! confirm "Start Jellyfin without a media directory?"; then
            return
        fi

    else

        if ! mountpoint -q "$media_path"; then

            error "Media storage is not mounted."
            echo
            echo "  $media_path"
            echo

            warning "Jellyfin may start, but the media libraries will be unavailable."
            echo

            if ! confirm "Start anyway?"; then
                return
            fi

        else

            success "Media storage mounted."

        fi

    fi

    echo

    info "Starting Jellyfin..."

    if compose up -d; then

        success "Jellyfin started."

    else

        error "Failed to start Jellyfin."

    fi

    pause
}

# ============================================================
# Stop
# ============================================================

stop_server() {

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

restart_server() {

    header

    check_jellyfin || {
        pause
        return
    }

    check_docker || {
        pause
        return
    }

    info "Restarting Jellyfin..."

    if compose restart; then

        success "Jellyfin restarted."

    else

        error "Failed to restart Jellyfin."

    fi

    pause
}

# ============================================================
# Logs
# ============================================================

logs_server() {

    check_jellyfin || return 1
    check_docker || return 1

    (
        cd "$JELLYFIN_DIR" || exit 1
        docker compose logs -f --tail=100 jellyfin
    )
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

    if tar \
        -czf "$backup_file" \
        -C "$JELLYFIN_DIR" \
        config \
        .env \
        docker-compose.yml \
        docker-compose.override.yml \
        2>/dev/null; then

        success "Backup completed."
        echo
        echo "  $backup_file"

    else

        warning "docker-compose.override.yml may not exist."
        info "Retrying without override file..."

        if tar \
            -czf "$backup_file" \
            -C "$JELLYFIN_DIR" \
            config \
            .env \
            docker-compose.yml; then

            success "Backup completed."
            echo
            echo "  $backup_file"

        else

            error "Backup failed."
            rm -f "$backup_file"

        fi

    fi

    pause
}

# ============================================================
# Update
# ============================================================

update_server() {

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

    info "Pulling latest Jellyfin image..."

    if ! compose pull jellyfin; then

        error "Failed to download the latest Jellyfin image."
        pause
        return

    fi

    echo

    info "Recreating Jellyfin..."

    if compose up -d jellyfin; then

        success "Jellyfin updated successfully."

    else

        error "Failed to recreate Jellyfin."

    fi

    pause
}

# ============================================================
# Install
# ============================================================

install_server() {

    header

    echo "Install"
    echo "────────────────────────────────────────"
    echo

    if [[ -d "$JELLYFIN_DIR" ]]; then

        warning "Jellyfin already exists."
        echo
        echo "  $JELLYFIN_DIR"

        pause
        return

    fi

    if ! install_dependencies; then

        pause
        return

    fi

    echo

    mkdir -p "$JELLYFIN_DIR"

    prepare_directories

    configure_timezone

    echo

    info "Creating Docker Compose configuration..."

    create_compose_file

    echo

    save_media_path "/mnt/jellyfin-media"

    local detected_hwaccel
    detected_hwaccel="$(detect_hwaccel)"

    info "Auto-detected hardware acceleration: $detected_hwaccel"

    if create_hardware_compose_override "$detected_hwaccel"; then
        save_hwaccel "$detected_hwaccel"
    else
        save_hwaccel "none"
        create_hardware_compose_override "none"
    fi

    echo

    info "Pulling Jellyfin image..."

    if ! compose pull; then

        error "Failed to pull Jellyfin image."

        pause
        return

    fi

    echo

    success "Jellyfin installation completed."

    echo
    echo "Jellyfin directory:"
    echo
    echo "  $JELLYFIN_DIR"
    echo

    info "Next steps:"
    echo
    echo "  1. Configure your media storage."
    echo "  2. Configure hardware acceleration if desired."
    echo "  3. Start Jellyfin."
    echo "  4. Configure Movies and TV Shows from the Jellyfin interface."
    echo

    if confirm "Start Jellyfin now?"; then

        start_server

    else

        info "Jellyfin remains OFFLINE."
        pause

    fi
}

# ============================================================
# Uninstall
# ============================================================

uninstall_server() {

    header

    check_jellyfin || {
        pause
        return
    }

    echo "Uninstall"
    echo "────────────────────────────────────────"
    echo

    echo "  1  Remove Jellyfin"
    echo "  2  Remove Jellyfin + configuration"
    echo "  0  Cancel"
    echo

    local choice

    read -r -p "Select: " choice

    case "$choice" in

        1)

            echo
            warning "Jellyfin containers and files will be removed."
            echo
            info "Configuration and media files will NOT be deleted."
            echo

            if ! confirm "Continue?"; then
                return
            fi

            compose down 2>/dev/null || true

            rm -rf -- \
                "$JELLYFIN_DIR"

            success "Jellyfin removed."

            ;;

        2)

            echo
            warning "This will remove Jellyfin, its configuration and cache."
            warning "Your external media storage will NOT be deleted."
            echo

            if ! confirm "THIS CANNOT BE UNDONE. Continue?"; then
                return
            fi

            compose down 2>/dev/null || true

            rm -rf -- \
                "$JELLYFIN_DIR"

            success "Jellyfin completely removed."

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

        if [[ -d "$JELLYFIN_DIR" ]] &&
           [[ -f "$COMPOSE_FILE" ]]; then

            if check_docker >/dev/null 2>&1 &&
               compose ps \
                    --status running \
                    --services 2>/dev/null |
               grep -qx "jellyfin"; then

                echo -e "Jellyfin    ${GREEN}● ONLINE${RESET}"

            else

                echo -e "Jellyfin    ${RED}● OFFLINE${RESET}"

            fi

        else

            echo -e "Jellyfin    ${DIM}○ NOT INSTALLED${RESET}"

        fi

        echo
        echo "  1  Start"
        echo "  2  Stop"
        echo "  3  Restart"
        echo "  4  Status"
        echo "  5  Logs"

        echo
        echo "  6  Backup"

        echo
        echo "  7  Configuration"

        echo
        echo "  8  Update"
        echo "  9  Install"
        echo  " 10  Uninstall"

        echo
        echo "  0  Exit"

        echo

        read -r -p "Select: " choice

        case "$choice" in

            1)
                start_server
                ;;

            2)
                stop_server
                ;;

            3)
                restart_server
                ;;

            4)
                status_server
                ;;

            5)
                logs_server
                ;;

            6)
                backup_jellyfin
                ;;

            7)
                configuration_menu
                ;;

            8)
                update_server
                ;;

            9)
                install_server
                ;;

            10)
                uninstall_server
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
        install_server
        ;;

    uninstall)
        uninstall_server
        ;;

    start)
        start_server
        ;;

    stop)
        stop_server
        ;;

    restart)
        restart_server
        ;;

    status)
        status_server
        ;;

    logs)
        logs_server
        ;;

    backup)
        backup_jellyfin
        ;;

    update)
        update_server
        ;;

    config)
        configuration_menu
        ;;

    media)
        configure_media_storage
        ;;

    hardware)
        configure_hardware_acceleration
        ;;

    diagnose)
        diagnose_hardware_acceleration
        ;;

    *)

        main_menu
        ;;

esac
