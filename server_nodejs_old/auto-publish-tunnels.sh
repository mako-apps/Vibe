#!/bin/bash
# ==============================================================================
# AUTO-PUBLISH TUNNEL URLS TO GITHUB GIST
# ==============================================================================
#
# This script:
# 1. Starts multiple tunnels (ngrok, pinggy, cloudflared)
# 2. Collects their URLs
# 3. Publishes them to a GitHub Gist (stable URL that's hard to block)
# 4. Users' apps fetch from the Gist to discover working servers
#
# SETUP:
# 1. Create a GitHub Personal Access Token with 'gist' scope
#    https://github.com/settings/tokens
# 2. Create a new Gist and note its ID
# 3. Set environment variables below
#
# ==============================================================================

# Configuration
export GITHUB_TOKEN="${GITHUB_TOKEN:-your_github_token_here}"
export GIST_ID="${GIST_ID:-your_gist_id_here}"
export SERVER_PORT="${SERVER_PORT:-3000}"
export UPDATE_SECRET="${UPDATE_SECRET:-securechat-update-2024}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${BLUE}[$(date '+%H:%M:%S')]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

# Store active tunnel URLs
declare -a ACTIVE_TUNNELS=()

# Cleanup function
cleanup() {
    log "Cleaning up tunnels..."
    pkill -f "ngrok" 2>/dev/null
    pkill -f "pinggy" 2>/dev/null
    pkill -f "cloudflared" 2>/dev/null
    pkill -f "localtunnel" 2>/dev/null
}
trap cleanup EXIT

# ==============================================================================
# TUNNEL FUNCTIONS
# ==============================================================================

start_ngrok() {
    log "Starting ngrok tunnel..."
    if ! command -v ngrok &> /dev/null; then
        warn "ngrok not installed. Install with: brew install ngrok"
        return 1
    fi
    
    # Start ngrok in background
    ngrok http $SERVER_PORT --log=stdout > /tmp/ngrok.log 2>&1 &
    sleep 3
    
    # Get URL from ngrok API
    local url=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | grep -o '"public_url":"https://[^"]*' | cut -d'"' -f4 | head -1)
    
    if [ -n "$url" ]; then
        success "ngrok: $url"
        ACTIVE_TUNNELS+=("{\"url\":\"$url\",\"name\":\"ngrok\",\"type\":\"tunnel\",\"addedAt\":$(date +%s)000}")
        return 0
    else
        error "Failed to start ngrok"
        return 1
    fi
}

start_pinggy() {
    log "Starting pinggy tunnel..."
    
    # Pinggy provides free tunnels without installation
    # Uses SSH for tunnel
    local result=$(ssh -o StrictHostKeyChecking=no -R 80:localhost:$SERVER_PORT a.pinggy.io 2>&1 &)
    sleep 5
    
    # Try to extract URL from pinggy (this is tricky, may need adjustment)
    # For now, skip if not working
    warn "Pinggy requires manual URL extraction - skipping auto-detection"
    return 1
}

start_cloudflared() {
    log "Starting cloudflared tunnel..."
    if ! command -v cloudflared &> /dev/null; then
        warn "cloudflared not installed. Install with: brew install cloudflared"
        return 1
    fi
    
    # Start cloudflared quick tunnel
    cloudflared tunnel --url http://localhost:$SERVER_PORT --no-autoupdate > /tmp/cloudflared.log 2>&1 &
    sleep 5
    
    # Get URL from log
    local url=$(grep -o 'https://[a-z0-9-]*\.trycloudflare\.com' /tmp/cloudflared.log | head -1)
    
    if [ -n "$url" ]; then
        success "cloudflared: $url"
        ACTIVE_TUNNELS+=("{\"url\":\"$url\",\"name\":\"cloudflare\",\"type\":\"tunnel\",\"addedAt\":$(date +%s)000}")
        return 0
    else
        error "Failed to start cloudflared"
        return 1
    fi
}

start_localtunnel() {
    log "Starting localtunnel..."
    if ! command -v lt &> /dev/null; then
        warn "localtunnel not installed. Install with: npm install -g localtunnel"
        return 1
    fi
    
    # Generate random subdomain
    local subdomain="securechat-$(openssl rand -hex 4)"
    
    lt --port $SERVER_PORT --subdomain $subdomain > /tmp/localtunnel.log 2>&1 &
    sleep 3
    
    local url="https://${subdomain}.loca.lt"
    
    # Verify it's working
    if curl -s --max-time 5 "$url/api/vapid-key" > /dev/null 2>&1; then
        success "localtunnel: $url"
        ACTIVE_TUNNELS+=("{\"url\":\"$url\",\"name\":\"localtunnel\",\"type\":\"tunnel\",\"addedAt\":$(date +%s)000}")
        return 0
    else
        error "localtunnel failed verification"
        return 1
    fi
}

# ==============================================================================
# PUBLISH TO GITHUB GIST
# ==============================================================================

publish_to_gist() {
    log "Publishing ${#ACTIVE_TUNNELS[@]} servers to GitHub Gist..."
    
    if [ "$GITHUB_TOKEN" == "your_github_token_here" ] || [ "$GIST_ID" == "your_gist_id_here" ]; then
        error "GitHub credentials not configured!"
        echo ""
        echo "To enable GitHub Gist publishing:"
        echo "1. Create a Personal Access Token: https://github.com/settings/tokens"
        echo "2. Create a Gist: https://gist.github.com/"
        echo "3. Set environment variables:"
        echo "   export GITHUB_TOKEN=your_token"
        echo "   export GIST_ID=your_gist_id"
        echo ""
        
        # Fall back to local file
        save_locally
        return 1
    fi
    
    # Build JSON content
    local servers_json="[$(IFS=,; echo "${ACTIVE_TUNNELS[*]}")]"
    local content=$(cat <<EOF
{
    "version": 1,
    "updatedAt": $(date +%s)000,
    "servers": $servers_json,
    "emergency": {
        "enabled": false,
        "p2pOnly": false,
        "message": ""
    }
}
EOF
)
    
    # Escape for JSON
    local escaped_content=$(echo "$content" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')
    
    # Update Gist
    local response=$(curl -s -X PATCH \
        -H "Authorization: token $GITHUB_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        "https://api.github.com/gists/$GIST_ID" \
        -d "{\"files\":{\"servers.json\":{\"content\":$escaped_content}}}")
    
    if echo "$response" | grep -q '"id"'; then
        success "Published to Gist: https://gist.github.com/$GIST_ID"
        echo ""
        echo "Raw URL (use in app):"
        echo "https://gist.githubusercontent.com/raw/$GIST_ID/servers.json"
        return 0
    else
        error "Failed to publish to Gist"
        echo "$response"
        save_locally
        return 1
    fi
}

save_locally() {
    log "Saving servers locally..."
    
    local servers_json="[$(IFS=,; echo "${ACTIVE_TUNNELS[*]}")]"
    
    # Save to server directory
    echo "$servers_json" > "$(dirname "$0")/servers.json"
    success "Saved to servers.json"
    
    # Also save to client public folder
    local client_path="$(dirname "$0")/../client/public/bootstrap-servers.json"
    cat > "$client_path" <<EOF
{
    "version": 1,
    "updatedAt": $(date +%s)000,
    "servers": $servers_json
}
EOF
    success "Saved to client/public/bootstrap-servers.json"
}

# ==============================================================================
# MAIN LOOP
# ==============================================================================

main() {
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║        SECURECHAT TUNNEL MANAGER                           ║"
    echo "║        Auto-publish URLs to GitHub Gist                    ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    
    # Check if server is running
    if ! curl -s "http://localhost:$SERVER_PORT/api/vapid-key" > /dev/null 2>&1; then
        error "Server is not running on port $SERVER_PORT"
        echo "Please start the server first: node server/index.js"
        exit 1
    fi
    success "Server running on port $SERVER_PORT"
    
    # Start tunnels
    echo ""
    log "Starting tunnels..."
    
    start_ngrok
    start_cloudflared
    # start_localtunnel  # Uncomment if needed
    # start_pinggy       # Uncomment if needed
    
    echo ""
    
    if [ ${#ACTIVE_TUNNELS[@]} -eq 0 ]; then
        error "No tunnels were started!"
        exit 1
    fi
    
    success "${#ACTIVE_TUNNELS[@]} tunnel(s) active"
    
    # Publish to Gist
    echo ""
    publish_to_gist
    
    # Keep alive and monitor
    echo ""
    log "Monitoring tunnels... (Press Ctrl+C to stop)"
    echo ""
    
    # Show URLs
    echo "Active Tunnel URLs:"
    for tunnel in "${ACTIVE_TUNNELS[@]}"; do
        local url=$(echo "$tunnel" | grep -o '"url":"[^"]*' | cut -d'"' -f4)
        local name=$(echo "$tunnel" | grep -o '"name":"[^"]*' | cut -d'"' -f4)
        echo "  • [$name] $url"
    done
    echo ""
    
    # Refresh loop - re-publish every 10 minutes
    while true; do
        sleep 600  # 10 minutes
        log "Refreshing tunnel status..."
        publish_to_gist
    done
}

main "$@"
