#!/bin/bash
# ==============================================================================
# SECURECHAT - AUTOMATIC GITHUB GIST SETUP
# ==============================================================================
# This script automatically:
# 1. Authenticates with GitHub (if needed)
# 2. Creates a Gist for server URLs
# 3. Configures the app to use this Gist
# ==============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        SECURECHAT - CENSORSHIP BYPASS SETUP                ║${NC}"
echo -e "${CYAN}║        Automatic GitHub Gist Configuration                 ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if gh CLI is installed
if ! command -v gh &> /dev/null; then
    error "GitHub CLI (gh) is not installed. Install with: brew install gh"
fi
success "GitHub CLI is installed"

# Check if already authenticated
log "Checking GitHub authentication..."
if ! gh auth status &> /dev/null; then
    warn "Not authenticated with GitHub. Starting login..."
    echo ""
    echo "Please complete the authentication in your browser."
    echo "Make sure to grant 'gist' scope permission."
    echo ""
    gh auth login --scopes gist
fi
success "Authenticated with GitHub"

# Get username
GITHUB_USER=$(gh api user -q '.login')
success "Logged in as: $GITHUB_USER"

# Check if gist already exists
GIST_FILE="servers.json"
EXISTING_GIST=$(gh gist list --limit 100 | grep -E "securechat-servers|$GIST_FILE" | head -1 | awk '{print $1}')

if [ -n "$EXISTING_GIST" ]; then
    log "Found existing gist: $EXISTING_GIST"
    echo ""
    read -p "Use existing gist? (y/n): " USE_EXISTING
    if [ "$USE_EXISTING" == "y" ]; then
        GIST_ID=$EXISTING_GIST
    else
        EXISTING_GIST=""
    fi
fi

# Create new gist if needed
if [ -z "$EXISTING_GIST" ]; then
    log "Creating new Gist for SecureChat servers..."
    
    # Create initial content
    INITIAL_CONTENT=$(cat <<EOF
{
    "version": 1,
    "updatedAt": $(date +%s)000,
    "servers": [],
    "emergency": {
        "enabled": false,
        "p2pOnly": false,
        "message": ""
    }
}
EOF
)
    
    # Create temp file
    TEMP_FILE=$(mktemp)
    echo "$INITIAL_CONTENT" > "$TEMP_FILE"
    
    # Create gist
    GIST_RESULT=$(gh gist create "$TEMP_FILE" --public --desc "SecureChat Server URLs (auto-updated)" --filename "$GIST_FILE")
    GIST_ID=$(echo "$GIST_RESULT" | grep -o '[a-f0-9]\{32\}')
    
    rm "$TEMP_FILE"
    
    if [ -z "$GIST_ID" ]; then
        # Try to extract from URL
        GIST_ID=$(echo "$GIST_RESULT" | grep -o 'gist.github.com/[^/]*/[a-f0-9]*' | cut -d'/' -f3)
    fi
fi

if [ -z "$GIST_ID" ]; then
    error "Failed to create/find Gist. Please check your GitHub permissions."
fi

success "Gist ID: $GIST_ID"

# Construct URLs
GIST_URL="https://gist.github.com/$GITHUB_USER/$GIST_ID"
RAW_URL="https://gist.githubusercontent.com/$GITHUB_USER/$GIST_ID/raw/$GIST_FILE"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                  GIST CREATED SUCCESSFULLY                  ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Gist URL:     ${CYAN}$GIST_URL${NC}"
echo -e "Raw URL:      ${CYAN}$RAW_URL${NC}"
echo ""

# Save configuration
CONFIG_DIR="$(dirname "$0")"
ENV_FILE="$CONFIG_DIR/.env"

log "Saving configuration to .env..."

# Create or update .env file
if [ -f "$ENV_FILE" ]; then
    # Update existing values
    grep -v "^GIST_ID=" "$ENV_FILE" | grep -v "^GITHUB_USER=" | grep -v "^BOOTSTRAP_URL=" > "$ENV_FILE.tmp"
    mv "$ENV_FILE.tmp" "$ENV_FILE"
fi

cat >> "$ENV_FILE" <<EOF
# GitHub Gist Configuration (auto-generated)
GIST_ID=$GIST_ID
GITHUB_USER=$GITHUB_USER
BOOTSTRAP_URL=$RAW_URL
EOF

success "Saved to $ENV_FILE"

# Update client bootstrap config
CLIENT_CONFIG="$CONFIG_DIR/../client/public/bootstrap-servers.json"
if [ -f "$CLIENT_CONFIG" ]; then
    log "Updating client bootstrap configuration..."
    
    cat > "$CLIENT_CONFIG" <<EOF
{
    "version": 1,
    "updatedAt": $(date +%s)000,
    "bootstrapUrls": [
        "$RAW_URL"
    ],
    "servers": [],
    "note": "Auto-configured on $(date '+%Y-%m-%d %H:%M')"
}
EOF
    success "Updated $CLIENT_CONFIG"
fi

# Get GitHub token for API updates
log "Getting GitHub token for automatic updates..."
GITHUB_TOKEN=$(gh auth token)

if [ -n "$GITHUB_TOKEN" ]; then
    # Add token to .env (masked in output)
    echo "GITHUB_TOKEN=$GITHUB_TOKEN" >> "$ENV_FILE"
    success "GitHub token saved to .env"
else
    warn "Could not retrieve GitHub token. You may need to set it manually."
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                    SETUP COMPLETE!                          ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo "Next steps:"
echo ""
echo "1. Start your server:"
echo -e "   ${CYAN}cd server && node index.js${NC}"
echo ""
echo "2. Start tunnels with auto-publish:"
echo -e "   ${CYAN}./auto-publish-tunnels.sh${NC}"
echo ""
echo "3. Your users' apps will automatically discover"
echo "   working servers from your Gist!"
echo ""
echo -e "Bootstrap URL for users: ${CYAN}$RAW_URL${NC}"
echo ""

# Test the gist
log "Testing Gist access..."
if curl -s "$RAW_URL" | grep -q "version"; then
    success "Gist is accessible and working!"
else
    warn "Gist created but may take a moment to be accessible."
fi

echo ""
echo "Done! 🚀"
