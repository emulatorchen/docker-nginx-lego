#!/bin/bash
# Runs an image the way a user would and checks everything that used to need
# root: binding ports 80 and 443, issuing a certificate, writing dhparams, the
# renewal loop and its SIGHUP restart, reloading Nginx, sharing certificates
# through NGINX_LEGO_CERT_GROUP, running under a uid the platform forces, and
# refusing to start on a volume it cannot write.
#
# The local CA issues the certificate, so this needs no network and no secrets.
#
# Usage: smoke_nonroot.sh <image>
#   SMOKE_DHPARAM=0     leave out the dhparam check (slow under emulation)
#   SMOKE_TIMEOUT=300   seconds to wait for a renewal pass
set -euo pipefail

image=${1:?usage: smoke_nonroot.sh <image>}
dhparam=${SMOKE_DHPARAM:-1}
timeout=${SMOKE_TIMEOUT:-300}
id=smoke-nonroot-$$
group=10443
work=$(mktemp -d)

cleanup() {
    docker rm -f "${id}" "${id}-uid" "${id}-root" > /dev/null 2>&1 || true
    docker volume rm -f "${id}" "${id}-uid" "${id}-root" > /dev/null 2>&1 || true
    rm -rf "${work}"
}
trap cleanup EXIT

fail() {
    echo "not ok - $*" >&2
    local c
    for c in "${id}" "${id}-uid"; do
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

# write_conf <dir> <with dhparam 0|1>: one HTTPS server on the local-CA certificate.
write_conf() {
    mkdir -p "$1"
    {
        echo 'server {'
        echo '    listen 443 ssl;'
        echo '    server_name smoke.example.org;'
        echo '    ssl_certificate     /etc/letsencrypt/live/smoke-cert/fullchain.pem;'
        echo '    ssl_certificate_key /etc/letsencrypt/live/smoke-cert/privkey.pem;'
        if [ "$2" = 1 ]; then
            echo '    ssl_dhparam         /etc/letsencrypt/dhparams/dhparam.pem;'
        fi
        # The \n is for nginx, so it must reach the file unexpanded.
        printf '%s\n' '    location / { return 200 "smoke ok\n"; }'
        echo '}'
    } > "$1/smoke.conf"
}

write_conf "${work}/conf" "${dhparam}"
write_conf "${work}/conf-plain" 0
# mktemp makes a 0700 directory; the container's user must be able to read it.
chmod -R a+rX "${work}"


[ "$(docker image inspect -f '{{.Config.User}}' "${image}")" = "101:101" ] \
    || fail "the image user is '$(docker image inspect -f '{{.Config.User}}' "${image}")', not 101:101"
ok "the image runs as 101:101"


# A volume written by an older, root-run container.
docker volume create "${id}-root" > /dev/null
docker run --rm --user 0 --entrypoint sh -v "${id}-root:/etc/letsencrypt" "${image}" \
    -c 'mkdir -p /etc/letsencrypt/accounts && chown -R 0:0 /etc/letsencrypt && chmod 755 /etc/letsencrypt'
set +e
out=$(timeout 120 docker run --rm --name "${id}-root" -e CERTBOT_EMAIL=smoke@example.org \
    -v "${id}-root:/etc/letsencrypt" "${image}" 2>&1)
rc=$?
set -e
[ "${rc}" -eq 1 ] || fail "on a root-owned volume the container exited ${rc}, not 1: ${out}"
grep -q 'chown -R 101:101 /etc/letsencrypt' <<< "${out}" \
    || fail "on a root-owned volume the container did not print the chown fix: ${out}"
ok "refuses a volume it cannot write, and prints the chown that fixes it"


docker run -d --name "${id}" --group-add "${group}" \
    -e CERTBOT_EMAIL=smoke@example.org -e USE_LOCAL_CA=1 -e RENEWAL_INTERVAL=9999d \
    -e NGINX_LEGO_CERT_GROUP="${group}" \
    -v "${work}/conf:/etc/nginx/user_conf.d:ro" -v "${id}:/etc/letsencrypt" \
    -p 127.0.0.1::80 -p 127.0.0.1::443 "${image}" > /dev/null
wait_for_log "${id}" "Autorenewal service will now sleep" 1
http=$(docker port "${id}" 80/tcp | head -n 1)
https=$(docker port "${id}" 443/tcp | head -n 1)

[ "$(docker exec "${id}" id -u)" = 101 ] || fail "docker exec runs as uid $(docker exec "${id}" id -u)"
ok "runs as uid 101"

# docker top needs a PID column in whatever ps format it is given.
others=$(docker top "${id}" -eo pid,uid,args | awk 'NR > 1 && $2 != 101')
[ -z "${others}" ] || fail "processes not running as uid 101: ${others}"
ok "no process runs as root"

[ "$(curl -fsSk "https://${https}/")" = "smoke ok" ] || fail "no answer on port 443"
ok "serves HTTPS on port 443"

[ "$(curl -s -o /dev/null -w '%{http_code}' "http://${http}/")" = 301 ] || fail "port 80 does not redirect"
ok "redirects HTTP on port 80"

if [ "${dhparam}" = 1 ]; then
    # Shared with NGINX_LEGO_CERT_GROUP like the certificates: DH parameters are
    # public, and a separate server has to read them.
    [ "$(docker exec "${id}" stat -c '%u %a %g' /etc/letsencrypt/dhparams/dhparam.pem)" = "101 640 ${group}" ] \
        || fail "dhparam.pem is not 0640, owned by uid 101 and group ${group}"
    ok "writes dhparams as uid 101, shared with group ${group}"
fi

for path in /etc/letsencrypt/live /etc/letsencrypt/live/smoke-cert; do
    [ "$(docker exec "${id}" stat -c '%a %g' "${path}")" = "750 ${group}" ] \
        || fail "${path} is not 0750 with group ${group}"
done
[ "$(docker exec "${id}" stat -c '%a %g' /etc/letsencrypt/live/smoke-cert/privkey.pem)" = "640 ${group}" ] \
    || fail "privkey.pem is not 0640 with group ${group}"
docker run --rm --user 4242:4242 --group-add "${group}" -v "${id}:/etc/letsencrypt:ro" \
    --entrypoint cat "${image}" /etc/letsencrypt/live/smoke-cert/privkey.pem > /dev/null \
    || fail "a container in group ${group} cannot read the key"
if docker run --rm --user 4242:4242 -v "${id}:/etc/letsencrypt:ro" \
    --entrypoint cat "${image}" /etc/letsencrypt/live/smoke-cert/privkey.pem > /dev/null 2>&1; then
    fail "a container outside group ${group} can read the key"
fi
ok "shares the certificate with group ${group}, and with no one else"

docker kill -s HUP "${id}" > /dev/null
wait_for_log "${id}" "Running the autorenewal service" 2
wait_for_log "${id}" "Autorenewal service will now sleep" 2
ok "SIGHUP runs the renewal loop again"

docker exec "${id}" nginx -s reload || fail "nginx -s reload failed"
sleep 2
[ "$(curl -fsSk "https://${https}/")" = "smoke ok" ] || fail "no answer on port 443 after a reload"
ok "nginx -s reload works"

if docker logs "${id}" 2>&1 | grep -i 'permission denied' >&2; then
    fail "a permission error was logged"
fi
ok "no permission errors in the log"


# OpenShift and Kubernetes runAsUser start the container as an arbitrary uid in group 0.
docker run -d --name "${id}-uid" --user 4321:0 \
    -e CERTBOT_EMAIL=smoke@example.org -e USE_LOCAL_CA=1 -e RENEWAL_INTERVAL=9999d \
    -v "${work}/conf-plain:/etc/nginx/user_conf.d:ro" -v "${id}-uid:/etc/letsencrypt" \
    -p 127.0.0.1::443 "${image}" > /dev/null
wait_for_log "${id}-uid" "Autorenewal service will now sleep" 1
[ "$(curl -fsSk "https://$(docker port "${id}-uid" 443/tcp | head -n 1)/")" = "smoke ok" ] \
    || fail "no answer on port 443 as uid 4321:0"
ok "works as a platform-assigned uid in group 0"

echo "all non-root checks passed for ${image}"
