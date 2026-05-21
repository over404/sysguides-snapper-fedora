#!/usr/bin/env bash

# install.sh
# ----------------
# Installs and configures Snapper + grub-btrfs on Fedora
# along with SysGuides Snapper integration scripts.
#
# This script:
# - Installs required packages (including git)
# - Configures Snapper (root only)
# - Sets permissions and ACLs
# - Configures updatedb to ignore snapshots
# - Installs grub-btrfs
# - Installs Snapper integration scripts (DNF5 actions)
#
# Project: sysguides-snapper-fedora
# Author: Madhu Desai (SysGuides)
# Website: https://sysguides.com
# GitHub: https://github.com/SysGuides/sysguides-snapper-fedora

# Exit on error, treat unset variables as errors, and fail on pipe errors
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

STEP=0
step() {
    STEP=$((STEP + 1))
    echo ""
    echo "[$STEP] $*"
}

die() {
    echo "Error: $*" >&2
    exit 1
}

# Get absolute path of this script (works regardless of current directory)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

# Prevent running as root
if [[ $EUID -eq 0 ]]; then
    die "Please run this script as a normal user: ./install.sh"
fi

# Resolve the real (non-sudo) username for snapper ACL config.
# SUDO_USER is set when the user ran a prior sudo command; fall back to $USER.
REAL_USER="${SUDO_USER:-$USER}"

# Verify Btrfs root before doing any work
if ! findmnt -n -o FSTYPE / | grep -q btrfs; then
    die "Root filesystem is not Btrfs"
fi

# Verify scripts directory is not empty before proceeding
if ! compgen -G "$SCRIPT_DIR/scripts/*" > /dev/null 2>&1; then
    die "No scripts found in $SCRIPT_DIR/scripts/ — aborting"
fi

# ---------------------------------------------------------------------------
# Step 1: Install packages
# ---------------------------------------------------------------------------

step "Installing required packages..."
# git is required for cloning grub-btrfs in step 4
sudo dnf install -y snapper libdnf5-plugin-actions btrfs-assistant inotify-tools make git

# ---------------------------------------------------------------------------
# Step 2: Configure Snapper (root only)
# ---------------------------------------------------------------------------

step "Configuring Snapper for / ..."

# Create root config if not already present.
# Check the snapper config directly — not the directory — because /.snapshots
# may exist from a previous failed run without a valid config behind it.
if ! sudo snapper -c root get-config &>/dev/null; then
    sudo snapper -c root create-config /
fi

# Fix SELinux contexts
sudo restorecon -RFv /.snapshots

# Allow current user to use snapper without sudo, and keep ACLs in sync.
# SUDO_USER takes precedence over USER so we get the actual human's account
# even when this script is invoked via sudo (though that is blocked above).
sudo snapper -c root set-config ALLOW_USERS="$REAL_USER" SYNC_ACL=yes

# ---------------------------------------------------------------------------
# Step 3: Update locate database config
# ---------------------------------------------------------------------------

step "Updating locate database config..."

UPDATEDB_CONF=/etc/updatedb.conf

if grep -q '\.snapshots' "$UPDATEDB_CONF"; then
    echo "==> .snapshots already excluded in $UPDATEDB_CONF — skipping"
elif grep -q '^PRUNENAMES' "$UPDATEDB_CONF"; then
    # Append .snapshots into the existing PRUNENAMES value.
    # The pattern anchors on the opening quote and is tolerant of spacing
    # variants such as PRUNENAMES="…", PRUNENAMES = "…", PRUNENAMES  =  "…"
    sudo sed -i 's|^\(PRUNENAMES\s*=\s*"\)|\1.snapshots |' "$UPDATEDB_CONF"
else
    echo 'PRUNENAMES = ".snapshots"' | sudo tee -a "$UPDATEDB_CONF"
fi

# ---------------------------------------------------------------------------
# Step 4: Install grub-btrfs
# ---------------------------------------------------------------------------

step "Installing grub-btrfs..."

tmpdir=$(mktemp -d)
# Always clean up the temp directory on exit, regardless of success/failure
trap 'rm -rf "$tmpdir"' EXIT

# Clone directly into a subdirectory of tmpdir, then enter it
git clone --depth 1 https://github.com/Antynea/grub-btrfs "$tmpdir/grub-btrfs"
cd "$tmpdir/grub-btrfs"

# Configure grub-btrfs for Fedora paths and kernel parameters
sed -i \
    -e 's|^#GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS=.*|GRUB_BTRFS_SNAPSHOT_KERNEL_PARAMETERS="rd.live.overlay.overlayfs=1"|' \
    -e 's|^#GRUB_BTRFS_GRUB_DIRNAME=.*|GRUB_BTRFS_GRUB_DIRNAME="/boot/grub2"|' \
    -e 's|^#GRUB_BTRFS_MKCONFIG=.*|GRUB_BTRFS_MKCONFIG=/usr/bin/grub2-mkconfig|' \
    -e 's|^#GRUB_BTRFS_SCRIPT_CHECK=.*|GRUB_BTRFS_SCRIPT_CHECK=grub2-script-check|' \
    config

sudo make install
sudo systemctl enable --now grub-btrfsd.service

echo "==> Updating GRUB configuration..."
sudo grub2-mkconfig -o /boot/grub2/grub.cfg

# ---------------------------------------------------------------------------
# Step 5: Install Snapper integration scripts
# ---------------------------------------------------------------------------

step "Installing Snapper integration scripts..."

# Install scripts to /usr/local/bin/
sudo install -m 755 "$SCRIPT_DIR"/scripts/* /usr/local/bin/

# Restore SELinux contexts for installed scripts
sudo restorecon -v /usr/local/bin/snapper-*.sh

# Install the DNF5 actions file
sudo mkdir -p /etc/dnf/libdnf5-plugins/actions.d/
sudo install -m 644 "$SCRIPT_DIR/config/snapper.actions" \
    /etc/dnf/libdnf5-plugins/actions.d/

# ---------------------------------------------------------------------------
# Step 6: Enable Snapper timers
# ---------------------------------------------------------------------------

step "Enabling Snapper timers..."

sudo systemctl enable --now snapper-timeline.timer
sudo systemctl enable --now snapper-cleanup.timer

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

echo ""
echo "✅ Installation complete!"
echo "Snapper is now fully integrated with DNF5 (CLI + GUI)."
echo "Snapshots are configured for / (root) only."
