#!/usr/bin/env bats
#
# validate_lego_migration.bats
#
# Validates the lego-only migration of run_lego.sh:
#   - determine_authenticator()  — cert name → webroot|dns-<provider>
#   - load_credentials()         — .ini file parsing (new KEY=VALUE + legacy dns-multi)
#   - map_key_type()             — honors RSA_KEY_SIZE and ELLIPTIC_CURVE env vars
#
# These tests source run_lego.sh in LEGO_FUNCTIONS_ONLY=1 mode, which loads only
# function definitions and skips the main execution block.
#
# Run with:
#   docker run -it --rm -v "$(pwd):/workdir" ffurrer/bats:latest ./tests

SCRIPTS_DIR="$(cd -- "${BATS_TEST_DIRNAME}/../src/scripts" &> /dev/null && pwd)"
FIXTURES_DIR="${BATS_TEST_DIRNAME}/fixtures/lego_migration"

# ---------------------------------------------------------------------------
# Setup: source run_lego.sh in functions-only mode so we can test its helpers.
# util.sh is sourced by run_lego.sh internally; we only need to set SCRIPTS_DIR
# here so the relative `source util.sh` inside run_lego.sh resolves correctly.
# ---------------------------------------------------------------------------
setup() {
    export CERTBOT_EMAIL="test@example.com"
    export STAGING="0"
    export LEGO_PATH="/tmp/lego-test-$$"
    export CERTBOT_DNS_CREDENTIALS_DIR="${FIXTURES_DIR}/creds"
    unset CERTBOT_AUTHENTICATOR
    unset LEGO_DEFAULT_PROVIDER
    unset RSA_KEY_SIZE
    unset ELLIPTIC_CURVE
    unset USE_ECDSA

    # Pre-load util.sh so run_lego.sh can skip its own util.sh source
    # (which would fail because $0 is the BATS runner path, not the script).
    . "${SCRIPTS_DIR}/util.sh"
    # Source run_lego.sh in functions-only mode (skips main execution block).
    LEGO_FUNCTIONS_ONLY=1 . "${SCRIPTS_DIR}/run_lego.sh"
}

# ===========================================================================
# determine_authenticator() — maps cert name to authenticator string
# ===========================================================================

@test "determine_authenticator: plain cert name defaults to webroot" {
    result=$(determine_authenticator "example.com")
    [ "${result}" = "webroot" ]
}

@test "determine_authenticator: cert name with .webroot suffix → webroot" {
    result=$(determine_authenticator "example.com.webroot")
    [ "${result}" = "webroot" ]
}

@test "determine_authenticator: cert name with .dns-cloudflare → dns-cloudflare" {
    result=$(determine_authenticator "example.com.dns-cloudflare")
    [ "${result}" = "dns-cloudflare" ]
}

@test "determine_authenticator: cert name with .dns-route53 → dns-route53" {
    result=$(determine_authenticator "example.com.dns-route53")
    [ "${result}" = "dns-route53" ]
}

@test "determine_authenticator: cert name with .dns-multi → dns-multi" {
    result=$(determine_authenticator "lalatina-freemyip.dns-multi")
    [ "${result}" = "dns-multi" ]
}

@test "determine_authenticator: cert name with .dns-multi_2 → dns-multi (suffix stripped for auth)" {
    result=$(determine_authenticator "lalatina-freemyip.dns-multi_2")
    [ "${result}" = "dns-multi" ]
}

@test "determine_authenticator: LEGO_DEFAULT_PROVIDER overrides default webroot" {
    export LEGO_DEFAULT_PROVIDER="cloudflare"
    result=$(determine_authenticator "example.com")
    [ "${result}" = "dns-cloudflare" ]
}

@test "determine_authenticator: CERTBOT_AUTHENTICATOR=dns-cloudflare overrides default" {
    export CERTBOT_AUTHENTICATOR="dns-cloudflare"
    result=$(determine_authenticator "example.com")
    [ "${result}" = "dns-cloudflare" ]
}

@test "determine_authenticator: CERTBOT_AUTHENTICATOR=webroot → webroot" {
    export CERTBOT_AUTHENTICATOR="webroot"
    result=$(determine_authenticator "example.com")
    [ "${result}" = "webroot" ]
}

@test "determine_authenticator: cert name dns-* takes priority over CERTBOT_AUTHENTICATOR" {
    export CERTBOT_AUTHENTICATOR="dns-cloudflare"
    result=$(determine_authenticator "example.com.dns-route53")
    [ "${result}" = "dns-route53" ]
}

@test "determine_authenticator: LEGO_DEFAULT_PROVIDER takes priority over CERTBOT_AUTHENTICATOR" {
    export LEGO_DEFAULT_PROVIDER="digitalocean"
    export CERTBOT_AUTHENTICATOR="dns-cloudflare"
    result=$(determine_authenticator "example.com")
    [ "${result}" = "dns-digitalocean" ]
}

# ===========================================================================
# load_credentials() — parses .ini files and emits PROVIDER= / ENV= lines
# ===========================================================================

@test "load_credentials: new KEY=VALUE format emits ENV lines" {
    output=$(load_credentials "cloudflare" "")
    echo "output: ${output}" >&2
    # Should contain the env var from cloudflare.ini
    echo "${output}" | grep -q "ENV=CLOUDFLARE_DNS_API_TOKEN=test-token-cf"
}

@test "load_credentials: new format does NOT emit a PROVIDER line" {
    output=$(load_credentials "cloudflare" "")
    # cloudflare.ini has no dns_multi_provider key, so no PROVIDER= line
    ! echo "${output}" | grep -q "^PROVIDER="
}

@test "load_credentials: suffixed file cloudflare_1.ini resolves correctly" {
    output=$(load_credentials "cloudflare" "_1")
    echo "${output}" | grep -q "ENV=CLOUDFLARE_DNS_API_TOKEN=test-token-cf-1"
}

@test "load_credentials: legacy multi.ini emits PROVIDER and ENV lines" {
    output=$(load_credentials "multi" "")
    echo "output: ${output}" >&2
    echo "${output}" | grep -q "^PROVIDER=cloudflare"
    echo "${output}" | grep -q "ENV=CLOUDFLARE_DNS_API_TOKEN=test-token-multi"
}

@test "load_credentials: legacy multi_2.ini with suffix resolves correctly" {
    output=$(load_credentials "multi" "_2")
    echo "${output}" | grep -q "^PROVIDER=digitalocean"
    echo "${output}" | grep -q "ENV=DO_AUTH_TOKEN=test-token-do-2"
}

@test "load_credentials: missing file returns non-zero exit code" {
    run load_credentials "nonexistent" ""
    [ "${status}" -ne 0 ]
}

@test "load_credentials: comments and blank lines are skipped" {
    output=$(load_credentials "cloudflare" "")
    # The comment line '# cloudflare.ini ...' must not appear as an env var
    ! echo "${output}" | grep -q "ENV=#"
}

# ===========================================================================
# map_key_type() — maps rsa/ecdsa to lego --key-type values
# ===========================================================================

@test "map_key_type: rsa → rsa2048 by default" {
    result=$(map_key_type "rsa")
    [ "${result}" = "rsa2048" ]
}

@test "map_key_type: rsa with RSA_KEY_SIZE=4096 → rsa4096" {
    export RSA_KEY_SIZE="4096"
    result=$(map_key_type "rsa")
    [ "${result}" = "rsa4096" ]
}

@test "map_key_type: rsa with RSA_KEY_SIZE=8192 → rsa8192" {
    export RSA_KEY_SIZE="8192"
    result=$(map_key_type "rsa")
    [ "${result}" = "rsa8192" ]
}

@test "map_key_type: ecdsa → EC256 by default (secp256r1)" {
    result=$(map_key_type "ecdsa")
    [ "${result}" = "EC256" ]
}

@test "map_key_type: ecdsa with ELLIPTIC_CURVE=secp384r1 → EC384" {
    export ELLIPTIC_CURVE="secp384r1"
    result=$(map_key_type "ecdsa")
    [ "${result}" = "EC384" ]
}

@test "map_key_type: ecdsa with ELLIPTIC_CURVE=secp256r1 → EC256" {
    export ELLIPTIC_CURVE="secp256r1"
    result=$(map_key_type "ecdsa")
    [ "${result}" = "EC256" ]
}

@test "map_key_type: unknown type → EC256 (safe default)" {
    result=$(map_key_type "unknown")
    [ "${result}" = "EC256" ]
}

# ===========================================================================
# Credential suffix extraction from cert name (B5)
# Validates that get_cert_provider_and_suffix() correctly parses cert names.
# ===========================================================================

@test "get_cert_provider_and_suffix: dns-cloudflare → provider=cloudflare suffix=''" {
    provider="" suffix=""
    get_cert_provider_and_suffix "example.com.dns-cloudflare"
    [ "${provider}" = "cloudflare" ]
    [ "${suffix}" = "" ]
}

@test "get_cert_provider_and_suffix: dns-cloudflare_1 → provider=cloudflare suffix=_1" {
    provider="" suffix=""
    get_cert_provider_and_suffix "example.com.dns-cloudflare_1"
    [ "${provider}" = "cloudflare" ]
    [ "${suffix}" = "_1" ]
}

@test "get_cert_provider_and_suffix: dns-multi → provider=multi suffix=''" {
    provider="" suffix=""
    get_cert_provider_and_suffix "lalatina-freemyip.dns-multi"
    [ "${provider}" = "multi" ]
    [ "${suffix}" = "" ]
}

@test "get_cert_provider_and_suffix: dns-multi_2 → provider=multi suffix=_2" {
    provider="" suffix=""
    get_cert_provider_and_suffix "lalatina-freemyip.dns-multi_2"
    [ "${provider}" = "multi" ]
    [ "${suffix}" = "_2" ]
}

# ===========================================================================
# get_certificate_lego() — lego 5.x command construction
# A mock 'lego' on PATH captures argv + injected env, so these run in CI with
# no network and no real issuance. Covers the lego-5.x correctness fixes:
#   - 'run' subcommand (lego 5.x has no 'renew'); flags are run options (after it)
#   - --renew-days (renewal window) + --ari-disable (cross-account ARI replace)
#   - cert-name suffix reaches load_credentials (was dropped into 'creds_suffix')
#   - names without a dns-<provider> token fall back to the authenticator
# ===========================================================================

_install_lego_mock() {
    MOCK_BIN="$(mktemp -d)"
    LEGO_ARGS_FILE="$(mktemp)"
    cat > "${MOCK_BIN}/lego" <<LEGO_MOCK_EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${LEGO_ARGS_FILE}"
env | grep -E '_TOKEN=|_DNS_API_TOKEN=|DO_AUTH_TOKEN=' >> "${LEGO_ARGS_FILE}" || true
exit 0
LEGO_MOCK_EOF
    chmod +x "${MOCK_BIN}/lego"
    PATH="${MOCK_BIN}:${PATH}"
}

@test "get_certificate_lego: invokes 'run' (not 'renew') with flags after the subcommand" {
    _install_lego_mock
    run get_certificate_lego "example.com.dns-cloudflare" "example.com" "ecdsa"
    [ "${status}" -eq 0 ]
    # lego 5.x: subcommand first, its options after it.
    [ "$(head -n1 "${LEGO_ARGS_FILE}")" = "run" ]
    ! grep -qx "renew" "${LEGO_ARGS_FILE}"
    grep -qx -- "--path" "${LEGO_ARGS_FILE}"
    local run_line path_line
    run_line=$(grep -nx "run" "${LEGO_ARGS_FILE}" | head -n1 | cut -d: -f1)
    path_line=$(grep -nx -- "--path" "${LEGO_ARGS_FILE}" | head -n1 | cut -d: -f1)
    [ "${path_line}" -gt "${run_line}" ]
}

@test "get_certificate_lego: includes --renew-days and --ari-disable" {
    _install_lego_mock
    run get_certificate_lego "example.com.dns-cloudflare" "example.com" "ecdsa"
    [ "${status}" -eq 0 ]
    grep -qx -- "--renew-days" "${LEGO_ARGS_FILE}"
    grep -qx -- "--ari-disable" "${LEGO_ARGS_FILE}"
}

@test "get_certificate_lego: suffixed cert name loads the matching creds file (suffix not dropped)" {
    _install_lego_mock
    run get_certificate_lego "example.com.dns-cloudflare_1" "example.com" "ecdsa"
    [ "${status}" -eq 0 ]
    grep -q "CLOUDFLARE_DNS_API_TOKEN=test-token-cf-1" "${LEGO_ARGS_FILE}"
}

@test "get_certificate_lego: cert name without dns- token falls back to CERTBOT_AUTHENTICATOR provider" {
    export CERTBOT_AUTHENTICATOR="dns-cloudflare"
    _install_lego_mock
    run get_certificate_lego "777777-duckdns" "mattermost.777777.duckdns.org" "ecdsa"
    [ "${status}" -eq 0 ]
    local dns_line
    dns_line=$(grep -nx -- "--dns" "${LEGO_ARGS_FILE}" | head -n1 | cut -d: -f1)
    [ -n "${dns_line}" ]
    [ "$(sed -n "$((dns_line + 1))p" "${LEGO_ARGS_FILE}")" = "cloudflare" ]
}
