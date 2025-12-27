#!/bin/bash
#
# SSO Flow Test Script for Signal K + Authelia Integration
#
# Tests that a user who is already authenticated with Authelia (e.g., from Homarr)
# can seamlessly access Signal K without re-authenticating.
#
# This tests the SSO (Single Sign-On) behavior - the Authelia session should be
# shared across all subdomains (*.halos.local).
#
# Usage:
#   ./test-sso-flow.sh [options]
#
# Options:
#   -h, --help              Show this help message
#   -u, --username USER     Authelia username (default: admin)
#   -p, --password PASS     Authelia password (required)
#   -d, --domain DOMAIN     Base domain (default: halos.local)
#   -v, --verbose           Show verbose output
#
# Test Scenarios:
#   1. Authenticate with Authelia directly (simulating Homarr login)
#   2. Verify Authelia session cookie is set with correct domain
#   3. Access Signal K OIDC login with existing Authelia session
#   4. Verify no re-authentication is required (automatic consent)
#   5. Verify Signal K login succeeds with admin permissions
#

set -euo pipefail

# Default values
USERNAME="${AUTHELIA_USERNAME:-admin}"
PASSWORD="${AUTHELIA_PASSWORD:-}"
DOMAIN="${HALOS_DOMAIN:-halos.local}"
VERBOSE=false
INSECURE=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    sed -n '2,/^$/p' "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_verbose() { $VERBOSE && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -u|--username) USERNAME="$2"; shift 2 ;;
        -p|--password) PASSWORD="$2"; shift 2 ;;
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$PASSWORD" ]]; then
    log_error "Password is required. Use -p or set AUTHELIA_PASSWORD"
    exit 1
fi

# URLs
SK_URL="https://signalk.${DOMAIN}"
AUTH_URL="https://auth.${DOMAIN}"
HOMARR_URL="https://${DOMAIN}"

# Output directory
OUTPUT_DIR="/tmp/sso_test_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

CURL_OPTS=(-s -k)
RESULTS=()
add_result() { RESULTS+=("$1"); }

echo "=============================================="
echo "SSO Flow Test for Signal K + Authelia"
echo "=============================================="
echo ""
echo "Configuration:"
echo "  Signal K URL: $SK_URL"
echo "  Authelia URL: $AUTH_URL"
echo "  Domain: $DOMAIN"
echo "  Output: $OUTPUT_DIR"
echo ""

#######################################
# Step 1: Authenticate with Authelia directly
# (simulating login through Homarr/Traefik)
#######################################
log "Step 1: Authenticating with Authelia (simulating Homarr login)..."

# First, initiate a session by visiting Authelia
curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    "$AUTH_URL/" -o step1a_authelia_home.html

# Authenticate
AUTH_RESPONSE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -X POST "$AUTH_URL/api/firstfactor" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"keepMeLoggedIn\":true}")

echo "$AUTH_RESPONSE" > step1_auth_response.json

AUTH_STATUS=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

if [[ "$AUTH_STATUS" == "OK" ]]; then
    log_success "Authenticated with Authelia"
    add_result "Step 1: PASS - Authelia authentication"
else
    log_error "Authelia authentication failed: $AUTH_RESPONSE"
    add_result "Step 1: FAIL - Authelia authentication"
    exit 1
fi

#######################################
# Step 2: Verify Authelia session cookie
#######################################
log "Step 2: Checking Authelia session cookie..."

echo "Cookies after Authelia login:" > step2_cookies.txt
cat cookies.txt >> step2_cookies.txt

# Check for authelia_session cookie
if grep -q "authelia_session" cookies.txt; then
    COOKIE_LINE=$(grep "authelia_session" cookies.txt)
    COOKIE_DOMAIN=$(echo "$COOKIE_LINE" | awk '{print $1}')
    log_success "Authelia session cookie found"
    log_verbose "Cookie domain: $COOKIE_DOMAIN"

    # Check if domain allows subdomain sharing
    if [[ "$COOKIE_DOMAIN" == ".${DOMAIN}" ]] || [[ "$COOKIE_DOMAIN" == "${DOMAIN}" ]]; then
        log_success "Cookie domain allows subdomain sharing: $COOKIE_DOMAIN"
        add_result "Step 2: PASS - Session cookie with correct domain"
    else
        log_warn "Cookie domain may not allow subdomain sharing: $COOKIE_DOMAIN"
        add_result "Step 2: WARN - Cookie domain: $COOKIE_DOMAIN"
    fi
else
    log_error "No authelia_session cookie found!"
    add_result "Step 2: FAIL - No session cookie"
    cat cookies.txt
fi

#######################################
# Step 3: Access Signal K OIDC login with existing session
#######################################
log "Step 3: Initiating Signal K OIDC login with existing Authelia session..."

# Start OIDC flow
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D step3_headers.txt -w "%{http_code}" \
    "$SK_URL/signalk/v1/auth/oidc/login" -o step3_body.html)

AUTHELIA_REDIRECT=$(grep -i "^location:" step3_headers.txt 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r\n')

if [[ "$HTTP_CODE" == "302" ]] && [[ -n "$AUTHELIA_REDIRECT" ]]; then
    log_success "Got redirect to Authelia"
    log_verbose "Redirect: $AUTHELIA_REDIRECT"
    add_result "Step 3: PASS - OIDC redirect"
else
    log_error "Failed to get OIDC redirect (HTTP $HTTP_CODE)"
    add_result "Step 3: FAIL - No OIDC redirect"
    exit 1
fi

#######################################
# Step 4: Follow Authelia redirect - should skip login
#######################################
log "Step 4: Following Authelia redirect (should use existing session)..."

# Follow redirects - with an existing session, Authelia should redirect directly to consent/callback
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D step4_headers.txt -L -w "%{http_code}" \
    --max-redirs 10 \
    "$AUTHELIA_REDIRECT" -o step4_body.html 2>&1)

# Check if we ended up at a login page or got redirected with a code
FINAL_LOCATION=$(grep -i "^location:" step4_headers.txt 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r\n')
BODY_CONTENT=$(cat step4_body.html)

log_verbose "Final HTTP code: $HTTP_CODE"
log_verbose "Final location: $FINAL_LOCATION"

# Check if we need to re-authenticate (SSO failure)
if echo "$BODY_CONTENT" | grep -qi "sign in\|login\|password" && [[ "$HTTP_CODE" == "200" ]]; then
    log_error "SSO FAILED: Authelia is showing login page instead of using existing session"
    log_error "This means the Authelia session cookie is not being shared across subdomains"
    add_result "Step 4: FAIL - SSO not working (login page shown)"

    echo ""
    echo "Debugging info:"
    echo "- Check that Authelia session domain is set to '.${DOMAIN}' (with leading dot)"
    echo "- Verify cookies are being sent to signalk.${DOMAIN}"
    echo ""
    echo "Current cookies:"
    cat cookies.txt
    exit 1
fi

# Check if we got an authorization code (success)
if [[ "$FINAL_LOCATION" == *"code="* ]]; then
    AUTH_CODE=$(echo "$FINAL_LOCATION" | sed -n 's/.*code=\([^&]*\).*/\1/p')
    log_success "SSO SUCCESS: Got authorization code without re-authentication"
    log_verbose "Code: ${AUTH_CODE:0:50}..."
    add_result "Step 4: PASS - SSO worked (no re-auth needed)"
    CALLBACK_URL="$FINAL_LOCATION"
else
    # Maybe we need to approve consent?
    log_warn "Did not get auth code directly. Checking for consent flow..."

    # Try to extract flow_id for consent
    FLOW_ID=$(echo "$FINAL_LOCATION" | sed -n 's/.*flow_id=\([^&]*\).*/\1/p')
    if [[ -z "$FLOW_ID" ]]; then
        FLOW_ID=$(echo "$BODY_CONTENT" | grep -o 'flow_id=[^"&]*' | head -1 | cut -d= -f2)
    fi

    if [[ -n "$FLOW_ID" ]]; then
        log "Found consent flow ID: $FLOW_ID, attempting to get consent redirect..."

        # Get consent redirect - user already authenticated, just need to authorize the client
        CONSENT_RESPONSE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
            "$AUTH_URL/api/oidc/authorization?client_id=signalk&flow_id=$FLOW_ID" \
            -D step4b_headers.txt -o step4b_body.html -w "%{http_code}")

        CALLBACK_URL=$(grep -i "^location:" step4b_headers.txt 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r\n')

        if [[ "$CALLBACK_URL" == *"code="* ]]; then
            log_success "Got authorization code after consent"
            add_result "Step 4: PASS - SSO worked (with consent)"
        else
            log_error "Failed to get authorization code"
            add_result "Step 4: FAIL - No auth code"
            exit 1
        fi
    else
        log_error "Could not find flow_id for consent"
        add_result "Step 4: FAIL - No flow_id"
        exit 1
    fi
fi

#######################################
# Step 5: Complete Signal K callback
#######################################
log "Step 5: Completing Signal K OIDC callback..."

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D step5_headers.txt -L -w "%{http_code}" \
    "$CALLBACK_URL" -o step5_body.html)

FINAL_REDIRECT=$(grep -i "^location:" step5_headers.txt 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r\n')

if [[ "$FINAL_REDIRECT" == *"oidcError=true"* ]]; then
    ERROR_MSG=$(echo "$FINAL_REDIRECT" | sed -n 's/.*message=\([^&]*\).*/\1/p' | python3 -c "import sys,urllib.parse; print(urllib.parse.unquote(sys.stdin.read()))" 2>/dev/null || echo "unknown")
    log_error "OIDC callback failed: $ERROR_MSG"
    add_result "Step 5: FAIL - $ERROR_MSG"
    exit 1
else
    log_success "OIDC callback completed"
    add_result "Step 5: PASS - Callback completed"
fi

#######################################
# Step 6: Verify login status
#######################################
log "Step 6: Verifying Signal K login status..."

LOGIN_STATUS=$(curl "${CURL_OPTS[@]}" -b cookies.txt "$SK_URL/skServer/loginStatus")
echo "$LOGIN_STATUS" > step6_login_status.json

USER_LEVEL=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('userLevel',''))" 2>/dev/null || echo "")
LOGGED_IN=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
USERNAME_SK=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")

echo ""
echo "Login Status:"
echo "$LOGIN_STATUS" | python3 -m json.tool 2>/dev/null || echo "$LOGIN_STATUS"
echo ""

if [[ "$LOGGED_IN" == "loggedIn" ]]; then
    log_success "User logged in: $USERNAME_SK"
    log "User level: $USER_LEVEL"

    if [[ "$USER_LEVEL" == "admin" ]]; then
        add_result "Step 6: PASS - Logged in as admin"
    else
        add_result "Step 6: WARN - Logged in as $USER_LEVEL (expected admin)"
    fi
else
    log_error "Not logged in!"
    add_result "Step 6: FAIL - Not logged in"
fi

#######################################
# Summary
#######################################
echo ""
echo "=============================================="
echo "SSO Test Summary"
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

# Overall result
if printf '%s\n' "${RESULTS[@]}" | grep -q "FAIL"; then
    echo ""
    log_error "SSO TEST FAILED"
    exit 1
else
    echo ""
    log_success "SSO TEST PASSED"
    exit 0
fi
