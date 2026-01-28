#!/bin/bash
# =============================================================================
# Home Assistant Config Sync to TrueNAS
# =============================================================================
# Uploads all HA config files to TrueNAS with automatic backups
# Uses sshpass for zero-password operation
#
# Usage: ./ha-sync.sh
#
# Revision: 3.1
# Updated: 2026-01-29
# Changes: 
#   - Fixed sudo permission denied error (use 'sudo bash' instead of 'sudo')
#   - Updated local path to new repo location
#   - Added packages/kitchen_lighting.yaml
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# CONFIGURATION - Edit these to match your setup
# -----------------------------------------------------------------------------
PASSWORD="img2mem"  # <-- SET YOUR TRUENAS PASSWORD HERE

REMOTE_USER="truenas_admin"
REMOTE_HOST="192.168.1.200"
REMOTE_HA_DIR="/mnt/Apps/Home_Ass_data"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

# Auto-detect script location (works from any directory)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_HA_DIR="$SCRIPT_DIR"

# Files to sync (relative to LOCAL_HA_DIR)
FILES=(
    "automations.yaml"
    "configuration.yaml"
    "scripts.yaml"
    "packages/sigenergy.yaml"
    "packages/kitchen_lighting.yaml"
)

# Temp files
LOCAL_TARBALL="/tmp/ha-config-$TIMESTAMP.tar.gz"
REMOTE_TARBALL="/tmp/ha-config-$TIMESTAMP.tar.gz"
LOCAL_INSTALL_SCRIPT="/tmp/ha-install-$TIMESTAMP.sh"
REMOTE_INSTALL_SCRIPT="/tmp/ha-install-$TIMESTAMP.sh"

# -----------------------------------------------------------------------------
# PREFLIGHT CHECKS
# -----------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 Home Assistant Config Sync → TrueNAS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Local:  $LOCAL_HA_DIR"
echo "   Remote: $REMOTE_USER@$REMOTE_HOST:$REMOTE_HA_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "🔍 Preflight checks..."

# Check sshpass
if ! command -v sshpass &> /dev/null; then
    echo "   ❌ sshpass not found. Install with: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi
echo "   ✓ sshpass found"

# Check password
if [[ "$PASSWORD" == "YOUR_PASSWORD_HERE" ]]; then
    echo "   ❌ Edit the script and set your PASSWORD first!"
    exit 1
fi
echo "   ✓ Password configured"
echo ""

SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR"

# -----------------------------------------------------------------------------
# CHECK LOCAL FILES
# -----------------------------------------------------------------------------
echo "🔍 Checking local files..."
SYNC_FILES=()
for f in "${FILES[@]}"; do
    if [[ -f "$LOCAL_HA_DIR/$f" ]]; then
        SIZE=$(ls -lh "$LOCAL_HA_DIR/$f" | awk '{print $5}')
        echo "   ✓ Found: $f ($SIZE)"
        SYNC_FILES+=("$f")
    else
        echo "   ⚠ Missing: $f (skipping)"
    fi
done
echo ""

if [[ ${#SYNC_FILES[@]} -eq 0 ]]; then
    echo "❌ No files to sync!"
    exit 1
fi

# -----------------------------------------------------------------------------
# CREATE TARBALL
# -----------------------------------------------------------------------------
echo "📦 Creating tarball..."
cd "$LOCAL_HA_DIR"
tar -czvf "$LOCAL_TARBALL" "${SYNC_FILES[@]}" 2>&1 | sed 's/^/   /'
echo "   ✓ Created: $(ls -lh "$LOCAL_TARBALL" | awk '{print $5}')"
echo ""

# -----------------------------------------------------------------------------
# TEST SSH CONNECTION
# -----------------------------------------------------------------------------
echo "🔐 Testing SSH connection..."
if sshpass -p "$PASSWORD" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "echo '   ✓ Connected to TrueNAS'"; then
    echo ""
else
    echo "   ❌ SSH connection failed!"
    rm -f "$LOCAL_TARBALL"
    exit 1
fi

# -----------------------------------------------------------------------------
# UPLOAD TARBALL
# -----------------------------------------------------------------------------
echo "⬆️  Uploading tarball..."
sshpass -p "$PASSWORD" scp $SSH_OPTS "$LOCAL_TARBALL" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_TARBALL"
echo "   ✓ Uploaded"
echo ""

# -----------------------------------------------------------------------------
# CREATE INSTALL SCRIPT
# -----------------------------------------------------------------------------
FILE_LIST="${SYNC_FILES[*]}"

cat > "$LOCAL_INSTALL_SCRIPT" << INSTALLSCRIPT
#!/bin/bash
set -e
echo "   📂 Changing to $REMOTE_HA_DIR"
cd "$REMOTE_HA_DIR"

echo "   📋 Backing up existing files..."
for f in $FILE_LIST; do
    if [[ -f "\$f" ]]; then
        BACKUP="\${f}.bak.$TIMESTAMP"
        mkdir -p "\$(dirname "\$BACKUP")"
        cp -a "\$f" "\$BACKUP"
        SIZE=\$(ls -lh "\$f" | awk '{print \$5}')
        echo "      ✓ Backed up: \$f (\$SIZE)"
    else
        echo "      ⚠ No existing: \$f (new file)"
    fi
done

echo "   📂 Creating directories..."
for f in $FILE_LIST; do
    DIR=\$(dirname "\$f")
    if [[ "\$DIR" != "." ]]; then
        mkdir -p "\$DIR"
    fi
done

echo "   📦 Extracting..."
tar -xzvf "$REMOTE_TARBALL" 2>&1 | while read line; do echo "      \$line"; done

echo "   🔒 Setting ownership..."
chown -R root:root .

echo "   🗑️  Cleanup..."
rm -f "$REMOTE_TARBALL" "$REMOTE_INSTALL_SCRIPT"

echo "   📋 Verifying..."
for f in $FILE_LIST; do
    if [[ -f "\$f" ]]; then
        SIZE=\$(ls -lh "\$f" | awk '{print \$5}')
        echo "      ✓ \$f (\$SIZE)"
    else
        echo "      ❌ \$f MISSING"
    fi
done
echo "   ✅ Done!"
INSTALLSCRIPT

# -----------------------------------------------------------------------------
# UPLOAD AND RUN INSTALL SCRIPT
# -----------------------------------------------------------------------------
echo "⬆️  Uploading install script..."
sshpass -p "$PASSWORD" scp $SSH_OPTS "$LOCAL_INSTALL_SCRIPT" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_INSTALL_SCRIPT"
echo "   ✓ Uploaded"
echo ""

# FIX: Use 'sudo bash' to run script instead of making it executable
# This avoids permission denied errors when /tmp has noexec mount option
echo "🔄 Running remote install..."
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "echo '$PASSWORD' | sudo -S bash $REMOTE_INSTALL_SCRIPT"

# -----------------------------------------------------------------------------
# CLEANUP
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Cleanup local temp files..."
rm -f "$LOCAL_TARBALL" "$LOCAL_INSTALL_SCRIPT"
echo "   ✓ Done"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Sync complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Next steps:"
echo "   1. Restart Home Assistant"
echo "   2. Check Developer Tools → YAML → Check Configuration first"
echo ""
