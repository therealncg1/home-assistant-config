#!/bin/bash
# =============================================================================
# Home Assistant + Zigbee2MQTT Config Sync to TrueNAS
# =============================================================================
# Revision: 6.1
# Updated: 2026-01-29
# 
# Syncs:
#   - HA config to /mnt/Apps/Home_Ass_data/
#   - Z2M config to /mnt/.ix-apps/app_mounts/zigbee2mqtt/data/
#
# Fixes in 6.1:
#   - Fixed macOS sed compatibility (BSD vs GNU)
#
# Fixes in 6.0:
#   - Sets proper file permissions (644) so HA can read them
#   - Removes kitchen_lighting.yaml (consolidated into scene_switches.yaml)
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
PASSWORD="img2mem"

REMOTE_USER="truenas_admin"
REMOTE_HOST="192.168.1.200"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)

HA_REMOTE_DIR="/mnt/Apps/Home_Ass_data"
Z2M_REMOTE_DIR="/mnt/.ix-apps/app_mounts/zigbee2mqtt/data"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOCAL_HA_DIR="$SCRIPT_DIR"

# Files to sync
HA_FILES=(
    "automations.yaml"
    "configuration.yaml"
    "scripts.yaml"
    "packages/sigenergy.yaml"
    "packages/scene_switches.yaml"
)

Z2M_FILES=(
    "configuration.yaml"
)

# Temp files
LOCAL_TARBALL="/tmp/ha-config-$TIMESTAMP.tar.gz"
REMOTE_TARBALL="/tmp/ha-config-$TIMESTAMP.tar.gz"
LOCAL_INSTALL_SCRIPT="/tmp/ha-install-$TIMESTAMP.sh"
REMOTE_INSTALL_SCRIPT="/tmp/ha-install-$TIMESTAMP.sh"

# -----------------------------------------------------------------------------
# PREFLIGHT
# -----------------------------------------------------------------------------
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📁 Config Sync → TrueNAS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "   Local:  $LOCAL_HA_DIR"
echo "   HA:     $HA_REMOTE_DIR"
echo "   Z2M:    $Z2M_REMOTE_DIR"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if ! command -v sshpass &> /dev/null; then
    echo "❌ sshpass not found. Install: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi

SSH_OPTS="-o StrictHostKeyChecking=no -o LogLevel=ERROR"

# -----------------------------------------------------------------------------
# CHECK LOCAL FILES
# -----------------------------------------------------------------------------
echo "🔍 Checking files..."
HA_SYNC_FILES=()
for f in "${HA_FILES[@]}"; do
    if [[ -f "$LOCAL_HA_DIR/$f" ]]; then
        echo "   ✓ $f"
        HA_SYNC_FILES+=("$f")
    else
        echo "   ⚠ Missing: $f"
    fi
done

Z2M_SYNC_FILES=()
for f in "${Z2M_FILES[@]}"; do
    if [[ -f "$LOCAL_HA_DIR/zigbee2mqtt/$f" ]]; then
        echo "   ✓ zigbee2mqtt/$f"
        Z2M_SYNC_FILES+=("zigbee2mqtt/$f")
    else
        echo "   ⚠ Missing: zigbee2mqtt/$f"
    fi
done
echo ""

if [[ ${#HA_SYNC_FILES[@]} -eq 0 && ${#Z2M_SYNC_FILES[@]} -eq 0 ]]; then
    echo "❌ No files to sync!"
    exit 1
fi

# -----------------------------------------------------------------------------
# CREATE TARBALL
# -----------------------------------------------------------------------------
echo "📦 Creating tarball..."
cd "$LOCAL_HA_DIR"
ALL_FILES=("${HA_SYNC_FILES[@]}" "${Z2M_SYNC_FILES[@]}")
tar -czf "$LOCAL_TARBALL" "${ALL_FILES[@]}"
echo "   ✓ Created $(ls -lh "$LOCAL_TARBALL" | awk '{print $5}')"
echo ""

# -----------------------------------------------------------------------------
# TEST CONNECTION
# -----------------------------------------------------------------------------
echo "🔐 Testing SSH..."
if ! sshpass -p "$PASSWORD" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "echo '   ✓ Connected'"; then
    echo "   ❌ SSH failed!"
    rm -f "$LOCAL_TARBALL"
    exit 1
fi
echo ""

# -----------------------------------------------------------------------------
# UPLOAD
# -----------------------------------------------------------------------------
echo "⬆️  Uploading..."
sshpass -p "$PASSWORD" scp $SSH_OPTS "$LOCAL_TARBALL" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_TARBALL"
echo "   ✓ Done"
echo ""

# -----------------------------------------------------------------------------
# CREATE INSTALL SCRIPT
# -----------------------------------------------------------------------------
HA_FILE_LIST="${HA_SYNC_FILES[*]}"
Z2M_FILE_LIST="${Z2M_SYNC_FILES[*]}"

cat > "$LOCAL_INSTALL_SCRIPT" << 'INSTALLSCRIPT'
#!/bin/bash
set -e

TIMESTAMP="TIMESTAMP_PLACEHOLDER"
HA_REMOTE_DIR="HA_DIR_PLACEHOLDER"
Z2M_REMOTE_DIR="Z2M_DIR_PLACEHOLDER"
REMOTE_TARBALL="TARBALL_PLACEHOLDER"
HA_FILE_LIST="HA_FILES_PLACEHOLDER"
Z2M_FILE_LIST="Z2M_FILES_PLACEHOLDER"

# Extract to temp
TEMP_DIR="/tmp/ha-extract-$TIMESTAMP"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"
tar -xzf "$REMOTE_TARBALL"

# =========================================================================
# HOME ASSISTANT FILES
# =========================================================================
if [[ -n "$HA_FILE_LIST" ]]; then
    echo ""
    echo "📂 Installing HA files..."
    cd "$HA_REMOTE_DIR"
    
    for f in $HA_FILE_LIST; do
        # Backup existing
        if [[ -f "$f" ]]; then
            cp -a "$f" "${f}.bak.$TIMESTAMP"
        fi
        
        # Create directory if needed
        DIR=$(dirname "$f")
        [[ "$DIR" != "." ]] && mkdir -p "$DIR"
        
        # Copy new file
        cp -a "$TEMP_DIR/$f" "$f"
        
        # SET PERMISSIONS - This is critical!
        chmod 644 "$f"
        chown root:root "$f"
        
        echo "   ✓ $f"
    done
    
    # Remove old kitchen_lighting.yaml if it exists
    if [[ -f "packages/kitchen_lighting.yaml" ]]; then
        mv "packages/kitchen_lighting.yaml" "packages/kitchen_lighting.yaml.disabled.$TIMESTAMP"
        echo "   🗑️  Disabled old kitchen_lighting.yaml"
    fi
    
    # Fix directory permissions
    chmod 755 packages/
fi

# =========================================================================
# ZIGBEE2MQTT FILES
# =========================================================================
if [[ -n "$Z2M_FILE_LIST" ]]; then
    echo ""
    echo "📂 Installing Z2M files..."
    cd "$Z2M_REMOTE_DIR"
    
    # Get current owner
    Z2M_OWNER=$(stat -c '%u:%g' . 2>/dev/null || echo "568:568")
    
    for f in $Z2M_FILE_LIST; do
        REMOTE_FILE="${f#zigbee2mqtt/}"
        
        # Backup existing
        if [[ -f "$REMOTE_FILE" ]]; then
            cp -a "$REMOTE_FILE" "${REMOTE_FILE}.bak.$TIMESTAMP"
        fi
        
        # Copy new file
        cp -a "$TEMP_DIR/$f" "$REMOTE_FILE"
        
        # SET PERMISSIONS for Z2M container
        chmod 644 "$REMOTE_FILE"
        chown $Z2M_OWNER "$REMOTE_FILE"
        
        echo "   ✓ $REMOTE_FILE (owner: $Z2M_OWNER)"
    done
fi

# =========================================================================
# CLEANUP
# =========================================================================
echo ""
echo "🗑️  Cleanup..."
rm -rf "$TEMP_DIR"
rm -f "$REMOTE_TARBALL"

echo "✅ Done!"
INSTALLSCRIPT

# Replace placeholders (macOS compatible)
sed -i.bak "s|TIMESTAMP_PLACEHOLDER|$TIMESTAMP|g" "$LOCAL_INSTALL_SCRIPT"
sed -i.bak "s|HA_DIR_PLACEHOLDER|$HA_REMOTE_DIR|g" "$LOCAL_INSTALL_SCRIPT"
sed -i.bak "s|Z2M_DIR_PLACEHOLDER|$Z2M_REMOTE_DIR|g" "$LOCAL_INSTALL_SCRIPT"
sed -i.bak "s|TARBALL_PLACEHOLDER|$REMOTE_TARBALL|g" "$LOCAL_INSTALL_SCRIPT"
sed -i.bak "s|HA_FILES_PLACEHOLDER|$HA_FILE_LIST|g" "$LOCAL_INSTALL_SCRIPT"
sed -i.bak "s|Z2M_FILES_PLACEHOLDER|$Z2M_FILE_LIST|g" "$LOCAL_INSTALL_SCRIPT"
rm -f "${LOCAL_INSTALL_SCRIPT}.bak"

# -----------------------------------------------------------------------------
# RUN INSTALL
# -----------------------------------------------------------------------------
echo "⬆️  Uploading install script..."
sshpass -p "$PASSWORD" scp $SSH_OPTS "$LOCAL_INSTALL_SCRIPT" "$REMOTE_USER@$REMOTE_HOST:$REMOTE_INSTALL_SCRIPT"

echo "🔄 Running install..."
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "echo '$PASSWORD' | sudo -S bash $REMOTE_INSTALL_SCRIPT"

# Cleanup remote install script
sshpass -p "$PASSWORD" ssh $SSH_OPTS "$REMOTE_USER@$REMOTE_HOST" "rm -f $REMOTE_INSTALL_SCRIPT"

# -----------------------------------------------------------------------------
# CLEANUP LOCAL
# -----------------------------------------------------------------------------
echo ""
rm -f "$LOCAL_TARBALL" "$LOCAL_INSTALL_SCRIPT"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✅ Sync complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Restart Zigbee2MQTT (if Z2M config changed)"
echo "  2. Developer Tools → YAML → Check Configuration"
echo "  3. Restart Home Assistant"
echo ""
