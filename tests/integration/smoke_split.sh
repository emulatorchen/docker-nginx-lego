#!/bin/bash
# Runs the image as two containers, the way examples/docker-compose-split.yml
# does: an issuer that runs lego and owns the certificate store, and a server
# that runs Nginx as another uid, read-only, with the store mounted read-only
# and no credentials. Checks that the server serves the issuer's certificate,
# cannot reach what only the issuer may, picks up a renewal, and refuses to run
# as the issuer's uid.
#
# The local CA issues the certificate, so this needs no network and no secrets.
#
# Usage: smoke_split.sh <image>
#   SMOKE_DHPARAM=0     leave out the dhparam check (slow under emulation)
#   SMOKE_TIMEOUT=300   seconds to wait for a renewal pass
set -euo pipefail

image=${1:?usage: smoke_split.sh <image>}
dhparam=${SMOKE_DHPARAM:-1}
timeout=${SMOKE_TIMEOUT:-300}
id=smoke-split-$$
group=10443
work=$(mktemp -d)

cleanup() {
    docker rm -f "${id}-issuer" "${id}-server" > /dev/null 2>&1 || true
    docker volume rm -f "${id}" > /dev/null 2>&1 || true
    rm -rf "${work}"
}
trap cleanup EXIT

fail() {
    echo "not ok - $*" >&2
    local c
    for c in "${id}-issuer" "${id}-server"; do
        docker logs "${c}" 2>&1 | tail -n 40 | sed "s/^/  ${c}: /" >&2 || true
    done
    exit 1
}

ok() {
    echo "ok - $*"
}

# wait_for_log <container> <text> <count>: until <text> has been logged <count> times.
wait_for_log() {
    local waited=0
    until [ "$(docker logs "$1" 2>&1 | grep -c -- "$2")" -ge "$3" ]; do
        [ -n "$(docker ps -q --filter "name=^$1\$")" ] || fail "$1 exited"
        [ "${waited}" -lt "${timeout}" ] || fail "$1: '$2' not logged $3 time(s) within ${timeout}s"
        sleep 2
        waited=$((waited + 2))
    done
}

# serial <host:port>: the serial number of the certificate served there.
serial() {
    openssl s_client -connect "$1" -servername smoke.example.org < /dev/null 2> /dev/null \
        | openssl x509 -noout -serial
}

mkdir -p "${work}/conf"
{
    echo 'server {'
    echo '    listen 443 ssl;'
    echo '    server_name smoke.example.org;'
    echo '    ssl_certificate     /etc/letsencrypt/live/smoke-cert/fullchain.pem;'
    echo '    ssl_certificate_key /etc/letsencrypt/live/smoke-cert/privkey.pem;'
    if [ "${dhparam}" = 1 ]; then
        echo '    ssl_dhparam         /etc/letsencrypt/dhparams/dhparam.pem;'
    fi
    # The \n is for nginx, so it must reach the file unexpanded.
    printf '%s\n' '    location / { return 200 "smoke ok\n"; }'
    echo '}'
} > "${work}/conf/smoke.conf"
# mktemp makes a 0700 directory; the containers' users must be able to read it.
chmod -R a+rX "${work}"


# The issuer: lego (here the local CA) and the store, no Nginx, no ports.
docker run -d --name "${id}-issuer" --group-add "${group}" \
    -e NGINX_LEGO_ROLE=issuer -e NGINX_LEGO_CERT_GROUP="${group}" \
    -e CERTBOT_EMAIL=smoke@example.org -e USE_LOCAL_CA=1 -e RENEWAL_INTERVAL=9999d \
    -v "${work}/conf:/etc/nginx/user_conf.d:ro" -v "${id}:/etc/letsencrypt" \
    "${image}" > /dev/null
wait_for_log "${id}-issuer" "Autorenewal service will now sleep" 1

# nginx names its processes "nginx: master process" and "nginx: worker process";
# a plain grep for "nginx" would match start_nginx_lego.sh itself. Output is read
# whole before grep -q: under pipefail an early grep exit fails the pipe.
procs=$(docker top "${id}-issuer" -eo pid,args)
if grep -q "nginx: master process" <<< "${procs}"; then
    fail "the issuer runs Nginx"
fi
[ -z "$(docker port "${id}-issuer")" ] || fail "the issuer publishes a port"
ok "the issuer runs no Nginx and publishes no port"

# A credentials file as a DNS-01 setup has it: only the issuer may read it.
docker exec "${id}-issuer" sh -c 'echo CLOUDFLARE_DNS_API_TOKEN=secret > /etc/letsencrypt/cloudflare.ini && chmod 600 /etc/letsencrypt/cloudflare.ini'


# The server: another uid, read-only, the store read-only, in the cert group.
server_args=(--user 102:0 --group-add "${group}" -e NGINX_LEGO_ROLE=server -e NGINX_LEGO_RELOAD_CHECK=2
    -v "${work}/conf:/etc/nginx/user_conf.d:ro" -v "${id}:/etc/letsencrypt:ro"
    --read-only --tmpfs /run:mode=1777 --tmpfs /var/cache/nginx:mode=1777
    --tmpfs /etc/nginx/conf.d:mode=1777 --tmpfs /tmp:mode=1777
    --cap-drop ALL --security-opt no-new-privileges)
docker run -d --name "${id}-server" "${server_args[@]}" \
    -p 127.0.0.1::80 -p 127.0.0.1::443 "${image}" > /dev/null
wait_for_log "${id}-server" "Starting the Nginx service" 1
sleep 2
http=$(docker port "${id}-server" 80/tcp | head -n 1)
https=$(docker port "${id}-server" 443/tcp | head -n 1)

[ "$(curl -fsSk "https://${https}/")" = "smoke ok" ] || fail "the server does not serve the issuer's certificate on 443"
ok "the server serves HTTPS with the issuer's certificate"

[ "$(curl -s -o /dev/null -w '%{http_code}' "http://${http}/")" = 301 ] \
    || fail "the server's port 80 does not redirect: the image's own config is missing"
ok "the server keeps the image's port 80 config on its read-only filesystem"

others=$(docker top "${id}-server" -eo pid,uid,args | awk 'NR > 1 && $2 != 102')
[ -z "${others}" ] || fail "server processes not running as uid 102: ${others}"
# The same match that finds no Nginx in the issuer must find it here.
procs=$(docker top "${id}-server" -eo pid,args | awk 'NR > 1 { $1 = ""; print }')
grep -q "nginx: master process" <<< "${procs}" || fail "no Nginx master process found in the server"
if grep -Eq "(^| |/)lego( |$)" <<< "${procs}"; then
    fail "the server runs lego"
fi
logs=$(docker logs "${id}-server" 2>&1)
! grep -q "Running the autorenewal service" <<< "${logs}" || fail "the server runs the renewal loop"
ok "every server process runs as uid 102, and none of them is lego"

if docker exec "${id}-server" ls /etc/letsencrypt/accounts > /dev/null 2>&1; then
    fail "the server can read the ACME account"
fi
if docker exec "${id}-server" cat /etc/letsencrypt/cloudflare.ini > /dev/null 2>&1; then
    fail "the server can read the DNS credentials"
fi
if docker exec "${id}-server" touch /etc/letsencrypt/written-by-server 2> /dev/null; then
    fail "the server can write the certificate store"
fi
ok "the server cannot read the account or the credentials, nor write the store"


# A renewal: the issuer re-issues, the server notices and reloads.
before=$(serial "${https}")
[ -n "${before}" ] || fail "no certificate serial read from the server"
docker exec "${id}-issuer" sh -c 'rm -f /etc/letsencrypt/live/smoke-cert/*.pem'
docker kill -s HUP "${id}-issuer" > /dev/null
wait_for_log "${id}-issuer" "Autorenewal service will now sleep" 2
wait_for_log "${id}-server" "reloading Nginx" 1
sleep 2
after=$(serial "${https}")
[ -n "${after}" ] && [ "${after}" != "${before}" ] \
    || fail "the server still serves the old certificate (${before}) after the renewal (${after})"
ok "the server reloads after the issuer renews, and serves the new certificate"

if docker logs "${id}-server" 2>&1 | grep -i 'permission denied' >&2; then
    fail "the server logged a permission error"
fi
ok "no permission errors in the server's log"


# A server with the issuer's uid could read everything the split is meant to hide.
set +e
out=$(timeout 120 docker run --rm --user 101:101 -e NGINX_LEGO_ROLE=server \
    -v "${work}/conf:/etc/nginx/user_conf.d:ro" -v "${id}:/etc/letsencrypt:ro" "${image}" 2>&1)
rc=$?
set -e
# 1 is the refusal; 124 would be timeout stopping a server that kept running.
[ "${rc}" -eq 1 ] || fail "a server running as the issuer's uid exited ${rc}, not 1 (124: it kept running)"
grep -q "another uid" <<< "${out}" || fail "a server running as the issuer's uid did not say why: ${out}"
ok "a server running as the issuer's uid refuses to start, and says why"

echo "all split checks passed for ${image}"
