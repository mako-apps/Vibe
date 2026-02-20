#!/bin/bash
# ==============================================================================
# DEPLOY SECURECHAT TO GITHUB PAGES
# ==============================================================================
# This creates a PERMANENT, STABLE URL for your users:
#   https://YOUR_USERNAME.github.io/SecureChat
#
# GitHub Pages is very hard to block because:
# - Used by millions of developers
# - Blocking github.io breaks too many things
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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CLIENT_DIR="$PROJECT_ROOT/client"

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║        SECURECHAT - DEPLOY TO GITHUB PAGES                 ║${NC}"
echo -e "${CYAN}║        Create a Permanent, Stable URL                      ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check prerequisites
if ! command -v gh &> /dev/null; then
    error "GitHub CLI (gh) not installed. Run: brew install gh"
fi

if ! command -v npm &> /dev/null; then
    error "npm not installed"
fi

# Check GitHub auth
if ! gh auth status &> /dev/null; then
    log "Please authenticate with GitHub..."
    gh auth login
fi

GITHUB_USER=$(gh api user -q '.login')
success "Logged in as: $GITHUB_USER"

# Repository name
REPO_NAME="SecureChat"
PAGES_URL="https://${GITHUB_USER}.github.io/${REPO_NAME}"

echo ""
log "Your app will be available at:"
echo -e "   ${CYAN}${PAGES_URL}${NC}"
echo ""

# Check if repo exists on GitHub
log "Checking if repository exists on GitHub..."
if gh repo view "$GITHUB_USER/$REPO_NAME" &> /dev/null; then
    success "Repository exists: $GITHUB_USER/$REPO_NAME"
else
    log "Creating GitHub repository..."
    gh repo create "$REPO_NAME" --public --description "SecureChat - Encrypted Messenger"
    success "Created repository: $GITHUB_USER/$REPO_NAME"
fi

# Ensure git remote is set
cd "$PROJECT_ROOT"
if ! git remote get-url origin &> /dev/null; then
    git remote add origin "https://github.com/$GITHUB_USER/$REPO_NAME.git"
fi

# Load Gist configuration
if [ -f "$SCRIPT_DIR/.env" ]; then
    source "$SCRIPT_DIR/.env"
fi

BOOTSTRAP_URL="https://gist.githubusercontent.com/$GITHUB_USER/$GIST_ID/raw/servers.json"

# Update bootstrap config
log "Updating bootstrap configuration..."
cat > "$CLIENT_DIR/public/bootstrap-servers.json" <<EOF
{
    "version": 1,
    "updatedAt": $(date +%s)000,
    "bootstrapUrls": [
        "$BOOTSTRAP_URL"
    ],
    "servers": [],
    "pagesUrl": "$PAGES_URL"
}
EOF
success "Bootstrap config updated"

# Set homepage in package.json for GitHub Pages
log "Configuring for GitHub Pages..."
cd "$CLIENT_DIR"

# Add homepage to package.json
if command -v jq &> /dev/null; then
    jq --arg url "$PAGES_URL" '.homepage = $url' package.json > package.json.tmp && mv package.json.tmp package.json
else
    # Fallback: use sed
    if grep -q '"homepage"' package.json; then
        sed -i.bak "s|\"homepage\":.*|\"homepage\": \"$PAGES_URL\",|" package.json
    else
        sed -i.bak 's|"name":|"homepage": "'"$PAGES_URL"'",\n  "name":|' package.json
    fi
    rm -f package.json.bak
fi

# Install gh-pages if not present
if ! npm list gh-pages &> /dev/null; then
    log "Installing gh-pages..."
    npm install --save-dev gh-pages
fi

# Add deploy script to package.json if not present
if ! grep -q '"deploy"' package.json; then
    log "Adding deploy script..."
    if command -v jq &> /dev/null; then
        jq '.scripts.predeploy = "npm run build" | .scripts.deploy = "gh-pages -d dist"' package.json > package.json.tmp && mv package.json.tmp package.json
    fi
fi

# Build the app
log "Building the application..."
npm run build

if [ ! -d "dist" ]; then
    # Try 'build' folder (Create React App)
    if [ -d "build" ]; then
        mv build dist
    else
        error "Build failed - no dist or build folder found"
    fi
fi

# Create CNAME file if custom domain (optional)
# echo "chat.yourdomain.com" > dist/CNAME

# Create 404.html for SPA routing
cp dist/index.html dist/404.html

# Deploy to GitHub Pages
log "Deploying to GitHub Pages..."
npx gh-pages -d dist -m "Deploy SecureChat $(date '+%Y-%m-%d %H:%M')"

success "Deployment complete!"

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}                 DEPLOYMENT SUCCESSFUL!                      ${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "Your app is now live at:"
echo ""
echo -e "   ${CYAN}${PAGES_URL}${NC}"
echo ""
echo -e "Share this URL with your users!"
echo ""
echo -e "This URL is:"
echo -e "  ✓ ${GREEN}Permanent${NC} - Never changes"
echo -e "  ✓ ${GREEN}Stable${NC} - Always works"
echo -e "  ✓ ${GREEN}Hard to block${NC} - github.io is trusted worldwide"
echo ""
echo -e "The app will automatically discover your backend"
echo -e "from your GitHub Gist, even when tunnel URLs change."
echo ""

# Enable GitHub Pages in repo settings
log "Enabling GitHub Pages..."
gh api -X PUT "/repos/$GITHUB_USER/$REPO_NAME/pages" \
    -f source='{"branch":"gh-pages","path":"/"}' 2>/dev/null || true

# Open in browser
if command -v open &> /dev/null; then
    read -p "Open in browser? (y/n): " OPEN_BROWSER
    if [ "$OPEN_BROWSER" == "y" ]; then
        open "$PAGES_URL"
    fi
fi

echo ""
echo "Done! 🚀"
