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
