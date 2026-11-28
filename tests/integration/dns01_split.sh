#!/bin/bash
# The real DNS-01 test, with one staging certificate per run: the split's issuer
# gets it from Let's Encrypt staging through the DNS provider, with the
# credentials mounted into it alone; the split's server serves it without them;
# then a single container started on the same store must use that certificate
# as it is, not order another one.
#
# Usage: dns01_split.sh <image> <cert_name> <domain> <credentials_dir> <conf_dir>
#   CERTBOT_EMAIL       the ACME account address (required)
#   DNS01_TIMEOUT=180   seconds to wait for the certificate
set -euo pipefail

image=${1:?usage: dns01_split.sh <image> <cert_name> <domain> <credentials_dir> <conf_dir>}
cert=${2:?cert name}
domain=${3:?domain}
creds=${4:?credentials dir}
conf=${5:?conf dir}
: "${CERTBOT_EMAIL:?CERTBOT_EMAIL is required}"
timeout=${DNS01_TIMEOUT:-180}
group=10443
volume=lego-test-certs
issuer=nginx-lego-issuer
server=nginx-lego-server
single=nginx-lego-test

fail() {
    echo "not ok - $*" >&2
    local c
    for c in "${issuer}" "${server}" "${single}"; do
        docker logs "${c}" 2>&1 | tail -n 60 | sed "s/^/  ${c}: /" >&2 || true
    done
    exit 1
}

ok() {
    echo "ok - $*"
}

wait_for_log() {
    local waited=0
    until [ "$(docker logs "$1" 2>&1 | grep -c -- "$2")" -ge "$3" ]; do
        [ -n "$(docker ps -q --filter "name=^$1\$")" ] || fail "$1 exited"
        [ "${waited}" -lt "${timeout}" ] || fail "$1: '$2' not logged $3 time(s) within ${timeout}s"
        sleep 3
        waited=$((waited + 3))
    done
}

# served <port>: issuer and subject of the certificate served on 127.0.0.1:<port>.
served() {
    openssl s_client -connect "127.0.0.1:$1" -servername "${domain}" < /dev/null 2> /dev/null \
        | openssl x509 -noout -issuer -ext subjectAltName
}

# crt_sum: the issued certificate file, as the issuer left it.
crt_sum() {
    docker run --rm --user 0 --entrypoint sh -v "${volume}:/etc/letsencrypt:ro" "${image}" \
        -c "sha256sum \"\$(readlink -f /etc/letsencrypt/live/${cert}/fullchain.pem)\"" | cut -d' ' -f1
}


# 1. The issuer orders the one staging certificate, by DNS-01.
docker run -d --name "${issuer}" --group-add "${group}" \
    -e NGINX_LEGO_ROLE=issuer -e NGINX_LEGO_CERT_GROUP="${group}" \
    -e CERTBOT_EMAIL="${CERTBOT_EMAIL}" -e STAGING=1 -e RENEWAL_INTERVAL=9999d \
    -e CERTBOT_DNS_CREDENTIALS_DIR=/etc/letsencrypt/credentials \
    -v "${creds}:/etc/letsencrypt/credentials:ro" -v "${conf}:/etc/nginx/user_conf.d:ro" \
    -v "${volume}:/etc/letsencrypt" "${image}" > /dev/null
wait_for_log "${issuer}" "Autorenewal service will now sleep" 1
docker exec "${issuer}" test -f "/etc/letsencrypt/live/${cert}/fullchain.pem" \
    || fail "the issuer finished its pass without a certificate for ${cert}"
ok "the issuer got a staging certificate by DNS-01"
tests/integration/check_cert_group.sh "${issuer}" "${cert}" "${group}" "${image}" "${volume}"


# 2. The server serves it, without the credentials and without the account.
docker run -d --name "${server}" --user 102:0 --group-add "${group}" -e NGINX_LEGO_ROLE=server \
    -v "${conf}:/etc/nginx/user_conf.d:ro" -v "${volume}:/etc/letsencrypt:ro" \
    --read-only --tmpfs /run:mode=1777 --tmpfs /var/cache/nginx:mode=1777 \
    --tmpfs /etc/nginx/conf.d:mode=1777 --tmpfs /tmp:mode=1777 \
    --cap-drop ALL --security-opt no-new-privileges -p 127.0.0.1:8443:443 "${image}" > /dev/null
wait_for_log "${server}" "Starting the Nginx service" 1
sleep 3
info=$(served 8443)
grep -qi "staging" <<< "${info}" || fail "the server does not serve the staging certificate: ${info}"
grep -q "DNS:${domain}" <<< "${info}" || fail "the served certificate is not for ${domain}: ${info}"
ok "the split's server serves the issuer's certificate for ${domain}"

if docker exec "${server}" ls /etc/letsencrypt/accounts > /dev/null 2>&1; then
    fail "the server can read the ACME account"
fi
if docker exec "${server}" sh -c 'cat /etc/letsencrypt/credentials/*.ini' > /dev/null 2>&1; then
    fail "the server can read the DNS credentials"
fi
ok "the server can read neither the ACME account nor the DNS credentials"

before=$(crt_sum)
docker rm -f "${issuer}" "${server}" > /dev/null


# 3. A single container on the same store keeps that certificate.
docker run -d --name "${single}" --group-add "${group}" \
    -e CERTBOT_EMAIL="${CERTBOT_EMAIL}" -e STAGING=1 -e RENEWAL_INTERVAL=9999d \
    -e NGINX_LEGO_CERT_GROUP="${group}" \
    -e CERTBOT_DNS_CREDENTIALS_DIR=/etc/letsencrypt/credentials \
    -v "${creds}:/etc/letsencrypt/credentials:ro" -v "${conf}:/etc/nginx/user_conf.d:ro" \
    -v "${volume}:/etc/letsencrypt" -p 127.0.0.1:8443:443 "${image}" > /dev/null
wait_for_log "${single}" "Autorenewal service will now sleep" 1
[ "$(crt_sum)" = "${before}" ] || fail "the single container ordered a second certificate"
ok "the single container kept the issuer's certificate and ordered no other"
tests/integration/check_cert_group.sh "${single}" "${cert}" "${group}" "${image}" "${volume}"
[ "$(curl -fsSk --resolve "${domain}:8443:127.0.0.1" "https://${domain}:8443/")" = "ok" ] \
    || fail "the single container does not serve ${domain}"
ok "the single container serves ${domain}"

echo "the DNS-01 split checks passed for ${image}"
