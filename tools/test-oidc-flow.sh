#!/bin/bash
#
# OIDC Flow Test Script for Signal K + Authelia Integration
#
# Tests the complete OIDC authentication flow and captures all
# requests, responses, headers, and tokens for debugging.
#
# Usage:
#   ./test-oidc-flow.sh [options]
#
# Options:
#   -h, --help              Show this help message
#   -u, --username USER     Authelia username (default: admin)
#   -p, --password PASS     Authelia password (required)
#   -d, --domain DOMAIN     Base domain (required, e.g., myhostname.local)
#   -o, --output DIR        Output directory (default: /tmp/oidc_test_<timestamp>)
#   -v, --verbose           Show verbose output
#   -k, --insecure          Allow insecure SSL (self-signed certs)
#
# Environment variables (alternative to options):
#   AUTHELIA_USERNAME, AUTHELIA_PASSWORD, HALOS_DOMAIN
#
# Examples:
#   ./test-oidc-flow.sh -p "MyPassword123"
#   ./test-oidc-flow.sh -d "myboat.local" -u "admin" -p "secret"
#   AUTHELIA_PASSWORD="secret" ./test-oidc-flow.sh
#

set -euo pipefail

# Default values
USERNAME="${AUTHELIA_USERNAME:-admin}"
PASSWORD="${AUTHELIA_PASSWORD:-}"
DOMAIN="${HALOS_DOMAIN:-}"
OUTPUT_DIR=""
VERBOSE=false
INSECURE=true  # Default to insecure for self-signed certs

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_verbose() {
    if $VERBOSE; then
        echo -e "${BLUE}[DEBUG]${NC} $*"
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            usage
            ;;
        -u|--username)
            USERNAME="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -d|--domain)
            DOMAIN="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -k|--insecure)
            INSECURE=true
            shift
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$PASSWORD" ]]; then
    log_error "Password is required. Use -p or set AUTHELIA_PASSWORD"
    exit 1
fi

if [[ -z "$DOMAIN" ]]; then
    log_error "Domain is required. Use -d or set HALOS_DOMAIN (e.g., myhostname.local)"
    exit 1
fi

# Set up URLs
SK_URL="https://signalk.${DOMAIN}"
AUTH_URL="https://auth.${DOMAIN}"

# Set up output directory
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="/tmp/oidc_test_$(date +%Y%m%d_%H%M%S)"
fi
mkdir -p "$OUTPUT_DIR"

# Curl options
CURL_OPTS=(-s)
if $INSECURE; then
    CURL_OPTS+=(-k)
fi

# Helper function to decode JWT
decode_jwt() {
    local jwt="$1"
    local payload
    payload=$(echo "$jwt" | cut -d'.' -f2)
    # Add padding if needed
    local padding=$((4 - ${#payload} % 4))
    if [[ $padding -ne 4 ]]; then
        payload="${payload}$(printf '=%.0s' $(seq 1 $padding))"
    fi
    echo "$payload" | base64 -d 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "$payload"
}

# Helper to extract header value
get_header() {
    local file="$1"
    local header="$2"
    grep -i "^${header}:" "$file" 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r\n'
}

echo "=============================================="
echo "OIDC Flow Test for Signal K + Authelia"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Signal K URL: $SK_URL"
echo "  Authelia URL: $AUTH_URL"
echo "  Username: $USERNAME"
echo "  Output: $OUTPUT_DIR"
echo ""

cd "$OUTPUT_DIR"

# Initialize results
RESULTS=()
add_result() {
    RESULTS+=("$1")
}

#######################################
# Step 1: Initiate OIDC Login
#######################################
log "Step 1: Initiating OIDC login..."

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -D step1_headers.txt \
    -w "%{http_code}" \
    "$SK_URL/signalk/v1/auth/oidc/login" -o step1_body.html)

AUTHELIA_REDIRECT=$(get_header step1_headers.txt "location")

if [[ "$HTTP_CODE" == "302" ]] && [[ -n "$AUTHELIA_REDIRECT" ]]; then
    log_success "Got redirect to Authelia"
    log_verbose "Redirect URL: $AUTHELIA_REDIRECT"
    add_result "Step 1: PASS - OIDC login initiated"
else
    log_error "Failed to initiate OIDC login (HTTP $HTTP_CODE)"
    add_result "Step 1: FAIL - HTTP $HTTP_CODE"
    exit 1
fi

# Check OIDC state cookie
if grep -q "OIDC_STATE" cookies.txt; then
    COOKIE_DOMAIN=$(grep "OIDC_STATE" cookies.txt | awk '{print $1}')
    COOKIE_SECURE=$(grep "OIDC_STATE" cookies.txt | awk '{print $4}')
    log_success "OIDC_STATE cookie set (domain: $COOKIE_DOMAIN, secure: $COOKIE_SECURE)"
else
    log_error "OIDC_STATE cookie not set!"
    add_result "Step 1b: FAIL - No state cookie"
fi

#######################################
# Step 2: Follow redirect to Authelia
#######################################
log "Step 2: Following redirect to Authelia..."

# Follow redirects to get to the login page
FINAL_URL=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt -L \
    -w "%{url_effective}" \
    "$AUTHELIA_REDIRECT" -o step2_body.html)

FLOW_ID=$(echo "$FINAL_URL" | sed -n 's/.*flow_id=\([^&]*\).*/\1/p')

if [[ -n "$FLOW_ID" ]]; then
    log_success "Got flow ID: $FLOW_ID"
    add_result "Step 2: PASS - Got flow ID"
else
    log_error "Failed to get flow ID from URL: $FINAL_URL"
    add_result "Step 2: FAIL - No flow ID"
    exit 1
fi

#######################################
# Step 3: Authenticate with Authelia
#######################################
log "Step 3: Authenticating with Authelia..."

AUTH_RESPONSE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -X POST "$AUTH_URL/api/firstfactor" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"keepMeLoggedIn\":false,\"flow\":\"openid_connect\",\"flowID\":\"$FLOW_ID\"}")

echo "$AUTH_RESPONSE" > step3_auth_response.json

AUTH_STATUS=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

if [[ "$AUTH_STATUS" == "OK" ]]; then
    log_success "Authentication successful"
    add_result "Step 3: PASS - Authenticated"
else
    log_error "Authentication failed: $AUTH_RESPONSE"
    add_result "Step 3: FAIL - Auth failed"
    exit 1
fi

# Extract consent redirect
CONSENT_REDIRECT=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('redirect',''))" 2>/dev/null | sed 's/\\u0026/\&/g')
log_verbose "Consent redirect: $CONSENT_REDIRECT"

#######################################
# Step 4: Get Authorization Code
#######################################
log "Step 4: Getting authorization code..."

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D step4_headers.txt -w "%{http_code}" \
    "$CONSENT_REDIRECT" -o step4_body.html)

CALLBACK_URL=$(get_header step4_headers.txt "location")

if [[ -n "$CALLBACK_URL" ]] && [[ "$CALLBACK_URL" == *"code="* ]]; then
    AUTH_CODE=$(echo "$CALLBACK_URL" | sed -n 's/.*code=\([^&]*\).*/\1/p')
    STATE=$(echo "$CALLBACK_URL" | sed -n 's/.*state=\([^&]*\).*/\1/p')
    log_success "Got authorization code"
    log_verbose "Code: ${AUTH_CODE:0:50}..."
    log_verbose "State: $STATE"
    add_result "Step 4: PASS - Got auth code"
else
    log_error "Failed to get authorization code"
    log_error "HTTP Code: $HTTP_CODE"
    log_error "Response: $(cat step4_body.html)"
    add_result "Step 4: FAIL - No auth code"
    exit 1
fi

#######################################
# Step 5: Complete OIDC Callback
#######################################
log "Step 5: Completing OIDC callback to Signal K..."

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D step5_headers.txt -L -w "%{http_code}" \
    "$CALLBACK_URL" -o step5_body.html)

# Check for error in redirect
FINAL_REDIRECT=$(get_header step5_headers.txt "location")
if [[ "$FINAL_REDIRECT" == *"oidcError=true"* ]]; then
    ERROR_MSG=$(echo "$FINAL_REDIRECT" | sed -n 's/.*message=\([^&]*\).*/\1/p' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))" 2>/dev/null || echo "unknown")
    log_error "OIDC callback failed: $ERROR_MSG"
    add_result "Step 5: FAIL - $ERROR_MSG"
else
    log_success "OIDC callback completed (HTTP $HTTP_CODE)"
    add_result "Step 5: PASS - Callback completed"
fi

#######################################
# Step 6: Check Login Status
#######################################
log "Step 6: Checking login status..."

LOGIN_STATUS=$(curl "${CURL_OPTS[@]}" -b cookies.txt "$SK_URL/skServer/loginStatus")
echo "$LOGIN_STATUS" > step6_login_status.json

USER_LEVEL=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('userLevel',''))" 2>/dev/null || echo "")
USERNAME_SK=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")
LOGGED_IN=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

echo ""
echo "Login Status:"
echo "$LOGIN_STATUS" | python3 -m json.tool 2>/dev/null || echo "$LOGIN_STATUS"
echo ""

if [[ "$LOGGED_IN" == "loggedIn" ]]; then
    log_success "User logged in: $USERNAME_SK"
    log "User level: $USER_LEVEL"
    add_result "Step 6: PASS - Logged in as $USER_LEVEL"
else
    log_error "Not logged in"
    add_result "Step 6: FAIL - Not logged in"
fi

#######################################
# Step 7: Decode JWT Token
#######################################
log "Step 7: Analyzing JWT token..."

JWT=$(grep "JAUTHENTICATION" cookies.txt 2>/dev/null | awk '{print $NF}' || echo "")
if [[ -n "$JWT" ]]; then
    echo ""
    echo "JWT Token Payload:"
    decode_jwt "$JWT"
    echo ""

    # Save decoded token
    decode_jwt "$JWT" > step7_jwt_decoded.json
    add_result "Step 7: PASS - JWT decoded"
else
    log_warn "No JWT token found in cookies"
    add_result "Step 7: SKIP - No JWT"
fi

#######################################
# Summary
#######################################
echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
for result in "${RESULTS[@]}"; do
    if [[ "$result" == *"PASS"* ]]; then
        echo -e "${GREEN}✓${NC} $result"
    elif [[ "$result" == *"FAIL"* ]]; then
        echo -e "${RED}✗${NC} $result"
    else
        echo -e "${YELLOW}○${NC} $result"
    fi
done

echo ""
echo "Output files saved to: $OUTPUT_DIR"
ls -la "$OUTPUT_DIR"

# Exit with error if user level is not admin when it should be
if [[ "$USER_LEVEL" == "readonly" ]]; then
    echo ""
    log_warn "User has readonly permissions. Check groups claim in Authelia."
    exit 2
fi
