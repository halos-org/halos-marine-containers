#!/bin/bash
#
# Comprehensive OIDC Test Suite for Signal K + Authelia
#
# Tests all OIDC functionality including:
# - Auto-login configuration
# - Admin permissions mapping
# - SSO session sharing
# - Fresh login flow
#
# Usage:
#   ./test-oidc-all.sh [options]
#
# Options:
#   -p, --password PASS     Authelia password (required)
#   -d, --domain DOMAIN     Base domain (default: halos.local)
#   -v, --verbose           Show verbose output
#

set -euo pipefail

# Default values
USERNAME="${AUTHELIA_USERNAME:-admin}"
PASSWORD="${AUTHELIA_PASSWORD:-}"
DOMAIN="${HALOS_DOMAIN:-halos.local}"
VERBOSE=false
INSECURE=true

# Colors
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
log_success() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_verbose() { $VERBOSE && echo -e "${BLUE}[DEBUG]${NC} $*" || true; }

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) usage ;;
        -p|--password) PASSWORD="$2"; shift 2 ;;
        -d|--domain) DOMAIN="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=true; shift ;;
        *) log_fail "Unknown option: $1"; usage ;;
    esac
done

if [[ -z "$PASSWORD" ]]; then
    log_fail "Password is required. Use -p or set AUTHELIA_PASSWORD"
    exit 1
fi

# URLs
SK_URL="https://signalk.${DOMAIN}"
AUTH_URL="https://auth.${DOMAIN}"

CURL_OPTS=(-s -k)

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

test_result() {
    local name="$1"
    local passed="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$passed" == "true" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        log_success "$name"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        log_fail "$name"
    fi
}

echo "=============================================="
echo "OIDC Comprehensive Test Suite"
echo "=============================================="
echo ""
echo "Target: $SK_URL"
echo "Auth: $AUTH_URL"
echo ""

#######################################
# TEST 1: Auto-login configuration
#######################################
echo ""
echo "--- Test 1: Auto-login Configuration ---"

LOGIN_STATUS=$(curl "${CURL_OPTS[@]}" "$SK_URL/skServer/loginStatus")
log_verbose "Login status: $LOGIN_STATUS"

OIDC_ENABLED=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('oidcEnabled', False))" 2>/dev/null || echo "false")
OIDC_AUTO_LOGIN=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('oidcAutoLogin', False))" 2>/dev/null || echo "false")
OIDC_LOGIN_URL=$(echo "$LOGIN_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('oidcLoginUrl', ''))" 2>/dev/null || echo "")

test_result "1.1 OIDC is enabled" "$( [[ "$OIDC_ENABLED" == "True" || "$OIDC_ENABLED" == "true" ]] && echo true || echo false )"
test_result "1.2 Auto-login is enabled" "$( [[ "$OIDC_AUTO_LOGIN" == "True" || "$OIDC_AUTO_LOGIN" == "true" ]] && echo true || echo false )"
test_result "1.3 OIDC login URL is set" "$( [[ -n "$OIDC_LOGIN_URL" ]] && echo true || echo false )"

#######################################
# TEST 2: OIDC Login Redirect
#######################################
echo ""
echo "--- Test 2: OIDC Login Redirect ---"

OUTPUT_DIR=$(mktemp -d)
cd "$OUTPUT_DIR"

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -D headers.txt \
    -w "%{http_code}" \
    "$SK_URL/signalk/v1/auth/oidc/login" -o body.html)

LOCATION=$(grep -i "^location:" headers.txt 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r\n')

test_result "2.1 OIDC login returns redirect (302)" "$( [[ "$HTTP_CODE" == "302" ]] && echo true || echo false )"
test_result "2.2 Redirect points to Authelia" "$( [[ "$LOCATION" == *"auth.${DOMAIN}"* ]] && echo true || echo false )"
test_result "2.3 OIDC_STATE cookie is set" "$( grep -q "OIDC_STATE" cookies.txt && echo true || echo false )"

#######################################
# TEST 3: Full Login Flow & Permissions
# Continues from Test 2's OIDC flow
#######################################
echo ""
echo "--- Test 3: Full Login Flow & Admin Permissions ---"

# Continue with existing cookies (including OIDC_STATE from Test 2)
# Don't clear cookies - we need the OIDC_STATE for the callback

# Follow redirect to Authelia (without following all the way - we need to authenticate)
FINAL_URL=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt -L \
    -w "%{url_effective}" \
    "$LOCATION" -o authelia.html)

FLOW_ID=$(echo "$FINAL_URL" | sed -n 's/.*flow_id=\([^&]*\).*/\1/p')
test_result "3.1 Got Authelia flow ID" "$( [[ -n "$FLOW_ID" ]] && echo true || echo false )"

# Authenticate
AUTH_RESPONSE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -X POST "$AUTH_URL/api/firstfactor" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$USERNAME\",\"password\":\"$PASSWORD\",\"keepMeLoggedIn\":true,\"flow\":\"openid_connect\",\"flowID\":\"$FLOW_ID\"}")

AUTH_STATUS=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
test_result "3.2 Authelia authentication succeeded" "$( [[ "$AUTH_STATUS" == "OK" ]] && echo true || echo false )"

# Get consent redirect and auth code
CONSENT_REDIRECT=$(echo "$AUTH_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('redirect',''))" 2>/dev/null | sed 's/\\u0026/\&/g')

HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D consent_headers.txt -w "%{http_code}" \
    "$CONSENT_REDIRECT" -o consent.html)

CALLBACK_URL=$(grep -i "^location:" consent_headers.txt 2>/dev/null | tail -1 | cut -d' ' -f2- | tr -d '\r\n')
log_verbose "Callback URL: $CALLBACK_URL"

# Ensure callback URL is absolute
if [[ "$CALLBACK_URL" == /* ]]; then
    CALLBACK_URL="${SK_URL}${CALLBACK_URL}"
fi

test_result "3.3 Got authorization code" "$( [[ "$CALLBACK_URL" == *"code="* ]] && echo true || echo false )"

# Check OIDC_STATE cookie before callback
log_verbose "Cookies before callback:"
$VERBOSE && cat cookies.txt || true

# Complete callback - need to handle redirects and cookie from signalk domain
log_verbose "Calling callback: $CALLBACK_URL"
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies.txt -b cookies.txt \
    -D callback_headers.txt -L -w "%{http_code}" \
    "$CALLBACK_URL" -o callback.html)

# Check if JAUTHENTICATION cookie was set
JAUTH_SET=$(grep -q "JAUTHENTICATION" cookies.txt && echo "true" || echo "false")
log_verbose "JAUTHENTICATION cookie set: $JAUTH_SET"
log_verbose "Callback headers:"
$VERBOSE && cat callback_headers.txt || true
log_verbose "Cookies after callback:"
$VERBOSE && cat cookies.txt || true

test_result "3.4 OIDC callback completed" "$( [[ "$HTTP_CODE" == "200" ]] && echo true || echo false )"
test_result "3.4b JAUTHENTICATION cookie set" "$JAUTH_SET"

# Verify login status
FINAL_STATUS=$(curl "${CURL_OPTS[@]}" -b cookies.txt "$SK_URL/skServer/loginStatus")
log_verbose "Final status: $FINAL_STATUS"

LOGGED_IN=$(echo "$FINAL_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")
USER_LEVEL=$(echo "$FINAL_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('userLevel',''))" 2>/dev/null || echo "")
USERNAME_SK=$(echo "$FINAL_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('username',''))" 2>/dev/null || echo "")

test_result "3.5 User is logged in" "$( [[ "$LOGGED_IN" == "loggedIn" ]] && echo true || echo false )"
test_result "3.6 User has admin permissions" "$( [[ "$USER_LEVEL" == "admin" ]] && echo true || echo false )"
test_result "3.7 Username is OIDC-based" "$( [[ "$USERNAME_SK" == oidc-* ]] && echo true || echo false )"

#######################################
# TEST 4: SSO Session Sharing
#######################################
echo ""
echo "--- Test 4: SSO Session Sharing ---"

# Start new OIDC flow using existing Authelia session
rm -f cookies_sso.txt
cp cookies.txt cookies_sso.txt  # Keep Authelia session

# Clear Signal K cookies
grep -v "signalk" cookies_sso.txt > cookies_sso_clean.txt || true
mv cookies_sso_clean.txt cookies_sso.txt

# Start OIDC flow - should use existing Authelia session
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies_sso.txt -b cookies_sso.txt \
    -D sso_step1.txt -w "%{http_code}" \
    "$SK_URL/signalk/v1/auth/oidc/login" -o sso_body1.html)

SSO_REDIRECT=$(grep -i "^location:" sso_step1.txt 2>/dev/null | head -1 | cut -d' ' -f2- | tr -d '\r\n')

# Follow redirect - with SSO, should get code directly without login
HTTP_CODE=$(curl "${CURL_OPTS[@]}" -c cookies_sso.txt -b cookies_sso.txt \
    -D sso_step2.txt -L -w "%{http_code}" --max-redirs 5 \
    "$SSO_REDIRECT" -o sso_body2.html)

# Check if we got a callback with code (SSO worked) or ended at login page
FINAL_LOCATION=$(grep -i "^location:" sso_step2.txt 2>/dev/null | grep "code=" | head -1 | cut -d' ' -f2- | tr -d '\r\n')

# Also check if body contains login form (SSO failed)
HAS_LOGIN_FORM=$(grep -qi "password\|sign in" sso_body2.html && echo "yes" || echo "no")

SSO_WORKED="false"
if [[ -n "$FINAL_LOCATION" ]] || [[ "$HAS_LOGIN_FORM" == "no" && "$HTTP_CODE" == "200" ]]; then
    # Either got code directly, or didn't get login form
    SSO_WORKED="true"
fi

test_result "4.1 SSO: No re-authentication required" "$SSO_WORKED"

#######################################
# Summary
#######################################
echo ""
echo "=============================================="
echo "Test Summary"
echo "=============================================="
echo -e "Total:  $TOTAL_TESTS"
echo -e "Passed: ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed: ${RED}$FAILED_TESTS${NC}"
echo ""

# Cleanup
rm -rf "$OUTPUT_DIR"

if [[ $FAILED_TESTS -gt 0 ]]; then
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
else
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
fi
