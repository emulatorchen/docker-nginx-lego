#!/bin/bash
set -e

# URLs used when requesting certificates.
: "${CERTBOT_PRODUCTION_URL=https://acme-v02.api.letsencrypt.org/directory}"
: "${CERTBOT_STAGING_URL=https://acme-staging-v02.api.letsencrypt.org/directory}"

# Source in util.sh so we can have our nice tools.
# Skip when sourced in functions-only mode (BATS tests pre-load util.sh).
if [ "${LEGO_FUNCTIONS_ONLY}" != "1" ]; then
    . "$(cd "$(dirname "$0")"; pwd)/util.sh"
fi

# ---------------------------------------------------------------------------
# FUNCTION DEFINITIONS
# All functions are defined before the main execution block so they can be
# sourced and tested independently:
#   LEGO_FUNCTIONS_ONLY=1 . run_lego.sh
# ---------------------------------------------------------------------------

# Map certbot key-type names to lego --key-type values.
# Honors RSA_KEY_SIZE (2048/4096/8192) and ELLIPTIC_CURVE (secp256r1/secp384r1).
map_key_type() {
    case "${1}" in
        rsa)
            local size="${RSA_KEY_SIZE:-2048}"
            case "${size}" in
                2048) echo "rsa2048" ;;
                4096) echo "rsa4096" ;;
                8192) echo "rsa8192" ;;
                *)    echo "rsa${size}" ;;
            esac
            ;;
        ecdsa)
            local curve="${ELLIPTIC_CURVE:-secp256r1}"
            case "${curve}" in
                secp256r1|prime256v1) echo "EC256" ;;
                secp384r1)           echo "EC384" ;;
                *)                   echo "EC256" ;;
            esac
            ;;
        *) echo "EC256" ;;
    esac
}

# determine_authenticator <cert_name>
#
# Returns the authenticator string for the given cert name:
#   "webroot"          — use HTTP-01 via lego --http --http.webroot
#   "dns-<provider>"   — use DNS-01 via lego --dns <provider>
#
# Priority order:
#   1. Explicit .webroot in cert name
#   2. Explicit .dns-<provider> in cert name
#   3. LEGO_DEFAULT_PROVIDER env var
#   4. CERTBOT_AUTHENTICATOR env var (backward compat)
#   5. Default: webroot
determine_authenticator() {
    local cert_name="${1}"

    # 1. Explicit webroot in cert name
    if [[ "${cert_name,,}" =~ (^|[-.])webroot([-.]|$) ]]; then
        echo "webroot"
        return
    fi

    # 2. Explicit dns-<provider> in cert name
    if [[ "${cert_name,,}" =~ (^|[-.])dns-([^-._]+)([-._]|$) ]]; then
        echo "dns-${BASH_REMATCH[2]}"
        return
    fi

    # 3. LEGO_DEFAULT_PROVIDER takes priority over CERTBOT_AUTHENTICATOR
    if [ -n "${LEGO_DEFAULT_PROVIDER}" ]; then
        echo "dns-${LEGO_DEFAULT_PROVIDER}"
        return
    fi

    # 4. CERTBOT_AUTHENTICATOR backward compat (strip dns- prefix if present)
    if [ -n "${CERTBOT_AUTHENTICATOR}" ]; then
        if [ "${CERTBOT_AUTHENTICATOR}" = "webroot" ]; then
            echo "webroot"
            return
        fi
        local provider="${CERTBOT_AUTHENTICATOR#dns-}"
        echo "dns-${provider}"
        return
    fi

    # 5. Default to webroot
    echo "webroot"
}

# get_cert_provider_and_suffix <cert_name>
#
# Sets caller-scope variables 'provider' and 'suffix' from the cert name.
# Handles both new-style and legacy patterns:
#   example.com.dns-cloudflare       → provider=cloudflare  suffix=
#   example.com.dns-cloudflare_1     → provider=cloudflare  suffix=_1
#   lalatina-freemyip.dns-multi      → provider=multi       suffix=
#   lalatina-freemyip.dns-multi_2    → provider=multi       suffix=_2
get_cert_provider_and_suffix() {
    local cert_name="${1}"
    provider=""
    suffix=""
    if [[ "${cert_name,,}" =~ (^|[-.])dns-([^-._]+)(_[^-.]+)?([-.]|$) ]]; then
        provider="${BASH_REMATCH[2]}"
        suffix="${BASH_REMATCH[3]}"
    fi
}

# load_credentials <provider> <suffix>
#
# Reads <CERTBOT_DNS_CREDENTIALS_DIR>/<provider><suffix>.ini and emits lines:
#   PROVIDER=<value>       — present only for legacy dns-multi format
#   ENV=KEY=VALUE          — one line per env var to export to lego
#
# Supported file formats:
#
#   New (lego-native, KEY=VALUE):
#     CLOUDFLARE_DNS_API_TOKEN=my-token
#
#   Legacy (dns-multi, backward compat):
#     dns_multi_provider = cloudflare
#     CLOUDFLARE_DNS_API_TOKEN = my-token
load_credentials() {
    local provider="${1}"
    local suffix="${2}"
    local creds_file="${CERTBOT_DNS_CREDENTIALS_DIR}/${provider}${suffix}.ini"

    if [ ! -f "${creds_file}" ]; then
        error "Credentials file '${creds_file}' not found"
        return 1
    fi

    local detected_provider=""
    local -a env_args=()
    while IFS= read -r line; do
        [[ "${line}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        local key value
        key=$(echo "${line}"  | cut -d= -f1  | tr -d ' ')
        value=$(echo "${line}" | cut -d= -f2- | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [ "${key}" = "dns_multi_provider" ]; then
            detected_provider="${value}"
        elif [ -n "${key}" ]; then
            env_args+=("${key}=${value}")
        fi
    done < "${creds_file}"

    if [ -n "${detected_provider}" ]; then
        echo "PROVIDER=${detected_provider}"
    fi
    for arg in "${env_args[@]}"; do
        echo "ENV=${arg}"
    done
}

# get_certificate_lego <cert_name> <domain_list> <key_type_str>
#
# Requests or renews a certificate via lego for any authenticator type:
#   - webroot: HTTP-01 via lego --http --http.webroot /var/www/letsencrypt
#     IMPORTANT: always use --http.webroot — never --http alone, as lego
#     would try to bind port 80 which nginx already owns.
#   - dns-<provider>: DNS-01 via lego --dns <provider> with env vars from .ini
#
# After obtaining the cert, symlinks lego output into the certbot-compatible
# /etc/letsencrypt/live/<cert_name>/ layout so nginx finds the expected paths.
get_certificate_lego() {
    local cert_name="${1}"
    local domains=($2)
    local key_type
    key_type=$(map_key_type "${3}")

    local authenticator
    authenticator=$(determine_authenticator "${cert_name}")

    # Build lego --domains args.
    local -a domain_args=()
    for d in "${domains[@]}"; do
        domain_args+=("--domains" "${d}")
    done

    # Determine the filename lego will use: first domain with '*' → '_'.
    local primary_domain="${domains[0]}"
    local lego_cert_name="${primary_domain//\*/_}"
    local lego_certs_dir="${LEGO_PATH}/certificates"
    local lego_cert="${lego_certs_dir}/${lego_cert_name}.crt"

    # Use 'run' for a new certificate, 'renew' for an existing one.
    local lego_subcmd="run"
    local lego_extra_args=()
    if [ -f "${lego_cert}" ]; then
        lego_subcmd="renew"
        [ -n "${force_renew}" ] && lego_extra_args+=("${force_renew}")
    fi

    if [ "${authenticator}" = "webroot" ]; then
        # HTTP-01 challenge via lego webroot.
        # Must always specify --http.webroot — never use --http alone.
        info "Requesting a ${key_type} certificate for '${cert_name}' (http-01 via lego webroot)"
        lego \
            --path       "${LEGO_PATH}" \
            --email      "${CERTBOT_EMAIL}" \
            --server     "${letsencrypt_url}" \
            --http \
            --http.webroot /var/www/letsencrypt \
            --key-type   "${key_type}" \
            --accept-tos \
            "${domain_args[@]}" \
            ${lego_subcmd} "${lego_extra_args[@]}" || return 1
    else
        # DNS-01 challenge.
        local provider="" creds_suffix=""
        get_cert_provider_and_suffix "${cert_name}"
        local dns_provider="${provider}"

        # For legacy dns-multi, the actual lego provider is inside the .ini file.
        local -a env_args=()
        if [ -n "${dns_provider}" ]; then
            local creds_output
            creds_output=$(load_credentials "${dns_provider}" "${creds_suffix}") || return 1

            # Override provider if the .ini file specifies dns_multi_provider.
            while IFS= read -r creds_line; do
                if [[ "${creds_line}" =~ ^PROVIDER=(.+)$ ]]; then
                    dns_provider="${BASH_REMATCH[1]}"
                elif [[ "${creds_line}" =~ ^ENV=(.+)$ ]]; then
                    env_args+=("${BASH_REMATCH[1]}")
                fi
            done <<< "${creds_output}"
        fi

        # route53 and similar providers that use env vars from the environment
        # (not from a .ini file) work without a creds file.

        info "Requesting a ${key_type} certificate for '${cert_name}' (dns-01 via lego/${dns_provider})"
        env "${env_args[@]}" lego \
            --path      "${LEGO_PATH}" \
            --email     "${CERTBOT_EMAIL}" \
            --server    "${letsencrypt_url}" \
            --dns       "${dns_provider}" \
            --key-type  "${key_type}" \
            --accept-tos \
            "${domain_args[@]}" \
            ${lego_subcmd} "${lego_extra_args[@]}" || return 1
    fi

    # Symlink lego output into certbot-compatible live/<cert_name>/ layout
    # so nginx finds fullchain.pem and privkey.pem at the expected paths.
    #
    #   lego output                      certbot equivalent
    #   <domain>.crt  (full chain)   ->  fullchain.pem
    #   <domain>.key  (private key)  ->  privkey.pem
    #   <domain>.issuer.crt (chain)  ->  chain.pem
    local live_dir="${LEGO_PATH}/live/${cert_name}"
    mkdir -p "${live_dir}"
    ln -sf "${lego_certs_dir}/${lego_cert_name}.crt"        "${live_dir}/fullchain.pem"
    ln -sf "${lego_certs_dir}/${lego_cert_name}.key"        "${live_dir}/privkey.pem"
    ln -sf "${lego_certs_dir}/${lego_cert_name}.issuer.crt" "${live_dir}/chain.pem"
    debug "Symlinked lego certs into '${live_dir}'"
}

# ---------------------------------------------------------------------------
# MAIN EXECUTION BLOCK
# Skip when sourced in functions-only mode (used by BATS tests).
# ---------------------------------------------------------------------------
if [ "${LEGO_FUNCTIONS_ONLY}" = "1" ]; then
    return 0 2>/dev/null || true
fi

info "Starting lego certificate renewal process"

# We require an email to be able to request a certificate.
if [ -z "${CERTBOT_EMAIL}" ]; then
    error "CERTBOT_EMAIL environment variable undefined; lego will do nothing!"
    exit 1
fi

# Use the correct challenge URL depending on if we want staging or not.
if [ "${STAGING}" = "1" ]; then
    debug "Using staging environment"
    letsencrypt_url="${CERTBOT_STAGING_URL}"
else
    debug "Using production environment"
    letsencrypt_url="${CERTBOT_PRODUCTION_URL}"
fi

# Directory where credentials .ini files are stored.
: "${CERTBOT_DNS_CREDENTIALS_DIR=/etc/letsencrypt}"

# Root path for lego storage; certificates land in ${LEGO_PATH}/certificates/.
: "${LEGO_PATH=/etc/letsencrypt}"

if [ "${1}" = "force" ]; then
    force_renew="--force"
fi

# Discover all cert names from nginx configs.
declare -A certificates
while IFS= read -r -d $'\0' conf_file; do
    parse_config_file "${conf_file}" certificates
done < <(find -L /etc/nginx/conf.d/ -name "*.conf*" -type f -print0)

# Process ALL certs — lego now handles every certificate type.
for cert_name in "${!certificates[@]}"; do
    server_names=(${certificates["${cert_name}"]})

    # Determine key type from cert name (same logic as run_certbot.sh).
    if [[ "${cert_name,,}" =~ (^|[-.])ecdsa([-.]|$) ]] || \
       [[ "${cert_name,,}" =~ (^|[-.])ecc([-.]|$) ]]; then
        key_type="ecdsa"
    elif [[ "${cert_name,,}" =~ (^|[-.])rsa([-.]|$) ]]; then
        key_type="rsa"
    elif [ "${USE_ECDSA}" = "0" ]; then
        key_type="rsa"
    else
        key_type="ecdsa"
    fi

    if ! get_certificate_lego "${cert_name}" "${server_names[*]}" "${key_type}"; then
        error "Lego failed for '${cert_name}'. Check the logs for details."
    fi
done

# Always enable configs regardless of whether lego renewed anything.
# This ensures configs with pre-existing certs on disk are properly enabled.
auto_enable_configs

if ! nginx -t; then
    error "Nginx configuration is invalid. Check the logs for details."
    exit 0
fi

nginx -s reload
