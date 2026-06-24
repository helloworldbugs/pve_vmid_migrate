#!/bin/bash
#===============================================================================
# pve_vmid_migrate.sh - Proxmox VE VM/CT ID Migration Tool
#===============================================================================
# Supports: QEMU VMs + LXC Containers (auto-detect)
# Tested on: PVE 9.2.x
# Usage:     bash pve_vmid_migrate.sh [options] <OLD_VMID> <NEW_VMID>
#
# Options:
#   --dry-run        Show what would happen without making changes
#   --skip-backups   Skip backup file migration
#   --no-color       Disable colored output
#   --log FILE       Write log to FILE (default: migrate_<OLD>_<NEW>.log)
#   --type qemu|lxc  Force VM type (auto-detect by default)
#===============================================================================

set -euo pipefail

#===============================================================================
# Globals & Defaults
#===============================================================================
SCRIPT_NAME="$(basename "$0")"
NODE_NAME="$(hostname)"
DRY_RUN=false
SKIP_BACKUPS=false
NO_COLOR=false
FORCE_TYPE=""
LOG_FILE=""
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

# Colors
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# Config paths
STORAGE_CFG="/etc/pve/storage.cfg"
QEMU_CONFIG_DIR="/etc/pve/qemu-server"
LXC_CONFIG_BASE="/etc/pve/nodes/${NODE_NAME}/lxc"

#===============================================================================
# Utility Functions
#===============================================================================

log_msg() {
    local level="$1"; shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] [${level}] ${msg}" >> "${LOG_FILE:?LOG_FILE not set}"
}

color_msg() {
    local color="$1"; shift
    local msg="$*"
    if $NO_COLOR; then
        echo "$msg"
    else
        echo -e "${color}${msg}${NC}"
    fi
}

info()    { color_msg "$BLUE"   "[INFO] $*";    log_msg "INFO" "$*"; }
warn()    { color_msg "$YELLOW" "[WARN] $*";    log_msg "WARN" "$*"; }
success() { color_msg "$GREEN"  "[OK]   $*";    log_msg "OK"   "$*"; }
error()   { color_msg "$RED"    "[ERROR] $*" >&2; log_msg "ERROR" "$*"; }

die() {
    error "$*"
    exit "${1:-1}"
}

check_cmd() {
    command -v "$1" >/dev/null 2>&1 || die 1 "Required command '$1' not found"
}

#===============================================================================
# Argument Parsing
#===============================================================================

usage() {
    cat <<EOF
Usage: bash ${SCRIPT_NAME} [options] <OLD_VMID> <NEW_VMID>

Options:
  --dry-run        Preview changes without applying them
  --skip-backups   Do not migrate backup files
  --no-color       Plain text output (for scripting)
  --log FILE       Custom log file path
  --type qemu|lxc  Force VM type instead of auto-detection
  -h, --help       Show this help

Examples:
  bash ${SCRIPT_NAME} 101 201                    # Migrate VM/CT 101 → 201
  bash ${SCRIPT_NAME} --dry-run 101 201          # Preview migration
  bash ${SCRIPT_NAME} --type lxc 110 210         # Force LXC type
EOF
    exit 0
}

parse_args() {
    local positional=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)     DRY_RUN=true; shift ;;
            --skip-backups) SKIP_BACKUPS=true; shift ;;
            --no-color)    NO_COLOR=true; shift ;;
            --log)         LOG_FILE="$2"; shift 2 ;;
            --type)        FORCE_TYPE="$2"; shift 2 ;;
            -h|--help)     usage ;;
            --*)           die 1 "Unknown option: $1" ;;
            *)             positional+=("$1"); shift ;;
        esac
    done

    if [[ ${#positional[@]} -ne 2 ]]; then
        error "Expected 2 positional arguments (OLD_VMID NEW_VMID), got ${#positional[@]}"
        echo ""
        usage
    fi

    OLD_VMID="${positional[0]}"
    NEW_VMID="${positional[1]}"
}

#===============================================================================
# Validation
#===============================================================================

validate_vmid() {
    local vmid="$1"
    local label="$2"

    # Must be a positive integer
    if [[ ! "$vmid" =~ ^[0-9]+$ ]]; then
        die 1 "${label} '${vmid}' is not a valid integer"
    fi

    # Proxmox reserves IDs < 100 for internal use
    if [[ "$vmid" -lt 100 ]]; then
        die 1 "${label} '${vmid}' is below 100 (reserved by Proxmox)"
    fi

    # Reasonable upper bound (Proxmox max is higher, but check sanity)
    if [[ "$vmid" -gt 999999 ]]; then
        die 1 "${label} '${vmid}' exceeds reasonable maximum (999999)"
    fi
}

validate_input() {
    validate_vmid "$OLD_VMID" "OLD_VMID"
    validate_vmid "$NEW_VMID" "NEW_VMID"

    if [[ "$OLD_VMID" -eq "$NEW_VMID" ]]; then
        die 1 "OLD_VMID and NEW_VMID are both ${OLD_VMID} — nothing to migrate"
    fi
}

#===============================================================================
# VM Type Detection
#===============================================================================

detect_vm_type() {
    local qemu_conf="${QEMU_CONFIG_DIR}/${OLD_VMID}.conf"
    local lxc_conf="${LXC_CONFIG_BASE}/${OLD_VMID}.conf"
    local qemu_exists=false
    local lxc_exists=false

    [[ -f "$qemu_conf" ]] && qemu_exists=true
    [[ -f "$lxc_conf" ]] && lxc_exists=true

    if $qemu_exists && $lxc_exists; then
        die 1 "VMID ${OLD_VMID} exists as BOTH QEMU and LXC — ambiguous. Use --type to specify."
    elif $qemu_exists; then
        VM_TYPE="qemu"
    elif $lxc_exists; then
        VM_TYPE="lxc"
    else
        die 1 "VMID ${OLD_VMID} not found (checked QEMU and LXC configs)"
    fi

    if [[ -n "$FORCE_TYPE" ]]; then
        if [[ "$FORCE_TYPE" != "$VM_TYPE" ]]; then
            warn "Auto-detected type is '${VM_TYPE}', but --type forces '${FORCE_TYPE}'"
            VM_TYPE="$FORCE_TYPE"
        fi
    fi
}

#===============================================================================
# Environment Checks
#===============================================================================

check_vm_status() {
    local status

    if [[ "$VM_TYPE" == "qemu" ]]; then
        # QEMU status check
        if [[ ! -f "${QEMU_CONFIG_DIR}/${OLD_VMID}.conf" ]]; then
            die 1 "QEMU config for VMID ${OLD_VMID} not found"
        fi
        if [[ -f "${QEMU_CONFIG_DIR}/${NEW_VMID}.conf" ]]; then
            die 1 "Target VMID ${NEW_VMID} already has a QEMU config"
        fi
        status=$(qm status "$OLD_VMID" 2>/dev/null | awk '{print $2}') || true
        if [[ "$status" != "stopped" ]]; then
            die 1 "QEMU VM ${OLD_VMID} is '${status:-unknown}'. Must be 'stopped' to migrate."
        fi

        CONFIG_DIR="$QEMU_CONFIG_DIR"
        STATUS_CMD="qm status"
        BACKUP_PREFIX="vzdump-qemu"
    else
        # LXC status check
        if [[ ! -f "${LXC_CONFIG_BASE}/${OLD_VMID}.conf" ]]; then
            die 1 "LXC config for VMID ${OLD_VMID} not found"
        fi
        if [[ -f "${LXC_CONFIG_BASE}/${NEW_VMID}.conf" ]]; then
            die 1 "Target VMID ${NEW_VMID} already has an LXC config"
        fi
        status=$(pct status "$OLD_VMID" 2>/dev/null | awk '{print $2}') || true
        if [[ "$status" != "stopped" ]]; then
            die 1 "LXC container ${OLD_VMID} is '${status:-unknown}'. Must be 'stopped' to migrate."
        fi

        CONFIG_DIR="$LXC_CONFIG_BASE"
        STATUS_CMD="pct status"
        BACKUP_PREFIX="vzdump-lxc"
    fi

    info "${VM_TYPE^^} ${OLD_VMID} exists and is stopped"
    info "Target ${NEW_VMID} is available"
}

#===============================================================================
# Storage Resolution
#===============================================================================

# Parse /etc/pve/storage.cfg to map: storage_name → filesystem_path
# Returns associative array via global STORAGE_PATHS
parse_storage_config() {
    declare -gA STORAGE_PATHS
    local current_name=""
    local current_path=""
    local current_type=""

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # New storage block
        if [[ "$line" =~ ^([a-z]+):[[:space:]]+(.+)$ ]]; then
            current_type="${BASH_REMATCH[1]}"
            current_name="${BASH_REMATCH[2]}"
            current_path=""
        fi

        # Path line
        if [[ "$line" =~ ^[[:space:]]+path[[:space:]]+(.+)$ ]]; then
            current_path="${BASH_REMATCH[1]}"
            if [[ -n "$current_name" && -n "$current_path" ]]; then
                STORAGE_PATHS["$current_name"]="$current_path"
            fi
        fi
    done < "$STORAGE_CFG"

    if [[ ${#STORAGE_PATHS[@]} -eq 0 ]]; then
        die 1 "No storage definitions found in ${STORAGE_CFG}"
    fi

    log_msg "INFO" "Parsed ${#STORAGE_PATHS[@]} storage(s): ${!STORAGE_PATHS[*]}"
}

# Resolve a storage:path to a filesystem path
# e.g., "local:101/vm-101-disk-0.raw" → "/var/lib/vz/images/101/vm-101-disk-0.raw"
resolve_storage_path() {
    local storage_name="$1"
    local rel_path="$2"    # e.g., "101/vm-101-disk-0.raw"
    local base_path

    base_path="${STORAGE_PATHS[$storage_name]:-}"
    if [[ -z "$base_path" ]]; then
        die 1 "Unknown storage '${storage_name}' (not found in ${STORAGE_CFG})"
    fi

    # PVE directory-based storage layout: $base/images/<vmid>/<file>
    echo "${base_path}/images/${rel_path}"
}

#===============================================================================
# Config File Migration
#===============================================================================

migrate_config() {
    local old_conf="${CONFIG_DIR}/${OLD_VMID}.conf"
    local new_conf="${CONFIG_DIR}/${NEW_VMID}.conf"

    if $DRY_RUN; then
        info "[DRY-RUN] Would rename ${old_conf} → ${new_conf}"
        info "[DRY-RUN] Would update VMID references in config file"
        return
    fi

    # Step 1: Rename config file
    if ! mv "$old_conf" "$new_conf"; then
        die 1 "Failed to rename config file ${old_conf} → ${new_conf}"
    fi
    info "Renamed config: ${OLD_VMID}.conf → ${NEW_VMID}.conf"

    # Step 2: Update VMID references inside config
    # Strategy: use targeted sed patterns to avoid false matches
    #
    # Pattern 1: disk image names (vm-X-disk-Y, base-X-disk-Y)
    #   Matches only when OLD_VMID is preceded by dash/colon and followed by -
    #   Safe: vm-10-disk won't match vm-100-disk (dash separates)
    sed -i \
        -e "s/vm-${OLD_VMID}-disk/vm-${NEW_VMID}-disk/g" \
        -e "s/base-${OLD_VMID}-disk/base-${NEW_VMID}-disk/g" \
        "$new_conf"

    # Pattern 2: storage path (storage:X/... → storage:Y/...)
    #   The ':' before VMID ensures we only match storage paths, not IPs or names
    sed -i \
        -e "s|:${OLD_VMID}/|:${NEW_VMID}/|g" \
        "$new_conf"

    # Pattern 3: vmid= parameter in QEMU configs
    if [[ "$VM_TYPE" == "qemu" ]]; then
        sed -i \
            -e "s/,vmid=${OLD_VMID}/,vmid=${NEW_VMID}/g" \
            "$new_conf"
    fi

    success "[1/4] Config file migrated"
}

#===============================================================================
# Extract Disk References from Config
#===============================================================================

# Parse config file for all disk/image lines
# Output format: storage|full_path_line|old_filepath
# Only returns lines containing storage:vmid/filename patterns
parse_disk_lines() {
    local conf_file="$1"
    local line value storage rel_path old_vmid_in_path filename

    while IFS= read -r line; do
        # Skip comments and empty
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        # Extract value part: everything after first colon (key: value)
        value="${line#*:}"
        value="${value# }"  # strip leading space

        # Extract the storage:path part (before any comma-separated options)
        local disk_ref
        if [[ "$value" == *,* ]]; then
            disk_ref="${value%%,*}"
        else
            disk_ref="$value"
        fi

        # Must match: storage_name:digits/filename
        if [[ ! "$disk_ref" =~ ^([a-zA-Z0-9_-]+):([0-9]+)/(.+)$ ]]; then
            continue
        fi

        storage="${BASH_REMATCH[1]}"
        old_vmid_in_path="${BASH_REMATCH[2]}"
        filename="${BASH_REMATCH[3]}"

        # Only process lines where the VMID in path matches OLD_VMID
        if [[ "$old_vmid_in_path" != "$OLD_VMID" ]]; then
            continue
        fi

        # Resolve to absolute path
        local abs_path
        abs_path=$(resolve_storage_path "$storage" "${OLD_VMID}/${filename}")

        echo "${storage}|${OLD_VMID}/${filename}|${abs_path}"
    done < "$conf_file"
}

#===============================================================================
# Disk File Migration
#===============================================================================

migrate_disks() {
    # Read from OLD config — disk references still have old VMID
    local conf_file="${CONFIG_DIR}/${OLD_VMID}.conf"
    local disk_lines migrated=0 skipped=0
    local -a lines_array

    mapfile -t lines_array < <(parse_disk_lines "$conf_file")

    if [[ ${#lines_array[@]} -eq 0 ]]; then
        warn "No disk references found in config — skipping disk migration"
        return
    fi

    info "Found ${#lines_array[@]} disk reference(s) to migrate"

    local storage old_rel new_rel old_abs new_abs old_dir new_dir filename

    for disk_line in "${lines_array[@]}"; do
        IFS='|' read -r storage old_rel old_abs <<< "$disk_line"

        # Build new paths
        filename="${old_rel#*/}"  # strip "VMID/" prefix
        new_rel="${NEW_VMID}/${filename}"
        new_abs=$(resolve_storage_path "$storage" "$new_rel")
        old_dir=$(dirname "$old_abs")
        new_dir=$(dirname "$new_abs")

        if [[ ! -e "$old_abs" ]]; then
            # Disk referenced in config but file doesn't exist
            # This is normal for empty cdrom, unused disks, or non-file storage
            info "  Disk '${old_rel}' → file not found on disk, skipped (may be on non-file storage)"
            ((skipped++)) || true
            continue
        fi

        if $DRY_RUN; then
            info "  [DRY-RUN] ${storage}: ${old_rel} → ${new_rel}"
            info "  [DRY-RUN]   ${old_abs} → ${new_abs}"
            ((migrated++)) || true
            continue
        fi

        # Create target directory
        if [[ ! -d "$new_dir" ]]; then
            mkdir -p "$new_dir" || die 1 "Failed to create directory: ${new_dir}"
        fi

        # Move the disk file
        if ! mv "$old_abs" "$new_abs"; then
            die 1 "Failed to move disk: ${old_abs} → ${new_abs}"
        fi
        info "  Moved: ${old_rel} → ${new_rel}"

        # Clean up old directory if empty
        if [[ -d "$old_dir" ]]; then
            rmdir "$old_dir" 2>/dev/null && \
                info "  Removed empty directory: ${old_dir}" || true
        fi

        ((migrated++)) || true
    done

    if [[ $migrated -gt 0 ]]; then
        success "[2/4] Disk files migrated (${migrated} file(s))"
    fi
    if [[ $skipped -gt 0 ]]; then
        warn "${skipped} disk reference(s) skipped (non-file storage or missing)"
    fi
}

#===============================================================================
# Backup File Migration
#===============================================================================

find_backup_dirs() {
    local dirs=()

    # Collect backup directories from all storage backends
    for storage_name in "${!STORAGE_PATHS[@]}"; do
        local base="${STORAGE_PATHS[$storage_name]}"
        local backup_dir="${base}/dump"
        if [[ -d "$backup_dir" ]]; then
            dirs+=("$backup_dir")
        fi
    done

    # Deduplicate
    printf '%s\n' "${dirs[@]}" | sort -u
}

migrate_backups() {
    if $SKIP_BACKUPS; then
        info "[SKIP] Backup migration disabled (--skip-backups)"
        return
    fi

    local backup_dirs migrated=0
    local -a dirs_array

    mapfile -t dirs_array < <(find_backup_dirs)

    if [[ ${#dirs_array[@]} -eq 0 ]]; then
        warn "No backup directories found — skipping"
        return
    fi

    for backup_dir in "${dirs_array[@]}"; do
        info "Scanning backups in: ${backup_dir}"

        # Use safe glob — only match files, handle empty gracefully
        local found=false
        local file newfile

        # Use nullglob to handle no matches
        shopt -s nullglob
        for file in "${backup_dir}/${BACKUP_PREFIX}-${OLD_VMID}-"*; do
            found=true

            # SAFE: Only replace the VMID in the prefix portion
            # "vzdump-qemu-100-2026_02_07-..." → "vzdump-qemu-200-2026_02_07-..."
            newfile="${file/${BACKUP_PREFIX}-${OLD_VMID}-/${BACKUP_PREFIX}-${NEW_VMID}-}"

            if $DRY_RUN; then
                info "  [DRY-RUN] ${file} → ${newfile}"
                ((migrated++)) || true
                continue
            fi

            if mv "$file" "$newfile"; then
                info "  Renamed: $(basename "$file") → $(basename "$newfile")"
                ((migrated++)) || true
            else
                error "  Failed to rename: $(basename "$file")"
            fi
        done
        shopt -u nullglob

        if ! $found; then
            info "  No matching backups in ${backup_dir}"
        fi
    done

    if [[ $migrated -gt 0 ]]; then
        success "[3/4] Backup files migrated (${migrated} file(s))"
    else
        info "[3/4] No backup files to migrate"
    fi
}

#===============================================================================
# Final Cleanup & Verification
#===============================================================================

verify_migration() {
    if $DRY_RUN; then
        info "[DRY-RUN] Skipping verification"
        return
    fi

    local new_conf="${CONFIG_DIR}/${NEW_VMID}.conf"
    local issues=0

    # Check new config exists
    if [[ ! -f "$new_conf" ]]; then
        error "New config file missing: ${new_conf}"
        ((issues++))
    fi

    # Check old config is gone
    local old_conf="${CONFIG_DIR}/${OLD_VMID}.conf"
    if [[ -f "$old_conf" ]]; then
        error "Old config file still exists: ${old_conf}"
        ((issues++))
    fi

    # Check new VMID is NOT in new config (no stale references)
    if [[ -f "$new_conf" ]]; then
        # Check for any remaining old VMID in disk paths
        if grep -qE ":${OLD_VMID}/" "$new_conf" 2>/dev/null; then
            warn "WARNING: Old VMID '${OLD_VMID}' still appears in config. Manual review recommended."
            grep -nE ":${OLD_VMID}/" "$new_conf" | while IFS= read -r match; do
                warn "  → ${match}"
            done
        fi
    fi

    # Verify via PVE tool
    if [[ "$VM_TYPE" == "qemu" ]]; then
        if qm status "$NEW_VMID" &>/dev/null; then
            success "QM ${NEW_VMID} is recognized by Proxmox"
        else
            warn "QM ${NEW_VMID} not recognized — may need to reload"
        fi
    else
        if pct status "$NEW_VMID" &>/dev/null; then
            success "CT ${NEW_VMID} is recognized by Proxmox"
        else
            warn "CT ${NEW_VMID} not recognized — may need to reload"
        fi
    fi

    success "[4/4] Verification complete (${issues} issue(s))"
}

#===============================================================================
# Main
#===============================================================================

main() {
    # Parse arguments
    parse_args "$@"

    # Set up logging
    if [[ -z "$LOG_FILE" ]]; then
        LOG_FILE="migrate_${OLD_VMID}_${NEW_VMID}_${TIMESTAMP}.log"
    fi
    log_msg "INFO" "=== Migration ${OLD_VMID} → ${NEW_VMID} started at ${TIMESTAMP} ==="

    # Validate
    validate_input
    check_cmd qm
    check_cmd pct
    detect_vm_type

    log_msg "INFO" "VM Type: ${VM_TYPE}, Node: ${NODE_NAME}, PVE: $(pveversion 2>/dev/null || echo unknown)"

    echo ""
    info "============================================"
    info " PVE VMID Migration Tool"
    info " Type: ${VM_TYPE^^}   ${OLD_VMID} → ${NEW_VMID}"
    info " Node: ${NODE_NAME}"
    if $DRY_RUN; then
        warn " DRY RUN MODE — no changes will be made"
    fi
    info "============================================"
    echo ""

    # Phase 0: Environment check
    check_vm_status
    parse_storage_config

    # Phase 1: Config migration
    migrate_config

    # Phase 2: Disk migration
    migrate_disks

    # Phase 3: Backup migration
    migrate_backups

    # Phase 4: Verify
    verify_migration

    # Done
    echo ""
    if $DRY_RUN; then
        success "============================================"
        success " DRY RUN COMPLETE — no changes were made"
        success " Run without --dry-run to apply"
        success "============================================"
    else
        success "============================================"
        success " Migration COMPLETE: ${OLD_VMID} → ${NEW_VMID}"
        success " Log saved to: ${LOG_FILE}"
        success "============================================"
        echo ""
        warn "IMPORTANT: Review your new ${VM_TYPE^^} ${NEW_VMID} config before starting."
        warn "  Check: disk paths, network MAC addresses, PCI passthrough refs"
    fi

    log_msg "INFO" "=== Migration completed ==="
}

# Run
main "$@"
