#!/bin/bash
# Checks that a running container shared the certificate it issued with a group:
# the key and the directories leading to it carry the group, the ACME account
# stays private, and another unprivileged container can read the key only while
# it is a member of that group.
#
# Usage: check_cert_group.sh <container> <cert_name> <group> <image> <volume>
set -euo pipefail

container=$1
cert=$2
group=$3
image=$4
volume=$5

fail() {
    echo "not ok - $*" >&2
    exit 1
}

mode_group() {
    docker exec "${container}" stat -c '%a %g' "$1"
}

key=$(docker exec "${container}" readlink -f "/etc/letsencrypt/live/${cert}/privkey.pem")

# The group is applied right after lego links the certificate into live/, so
# give it a moment once the certificate has appeared.
for _ in $(seq 1 15); do
    [ "$(mode_group "${key}")" = "640 ${group}" ] && break
    sleep 2
done
[ "$(mode_group "${key}")" = "640 ${group}" ] || fail "${key} is $(mode_group "${key}"), not 640 ${group}"
[ "$(mode_group "$(dirname "${key}")")" = "750 ${group}" ] || fail "$(dirname "${key}") is not 750 ${group}"
[ "$(mode_group "/etc/letsencrypt/live/${cert}")" = "750 ${group}" ] || fail "live/${cert} is not 750 ${group}"
[ "$(docker exec "${container}" stat -c '%a' /etc/letsencrypt/accounts)" = 700 ] || fail "accounts/ is no longer 0700"
echo "ok - the issued key is 0640 with group ${group}; the ACME account stays 0700"

docker run --rm --user 4242:4242 --group-add "${group}" -v "${volume}:/etc/letsencrypt:ro" \
    --entrypoint cat "${image}" "/etc/letsencrypt/live/${cert}/privkey.pem" > /dev/null \
    || fail "a container in group ${group} cannot read the key"
if docker run --rm --user 4242:4242 -v "${volume}:/etc/letsencrypt:ro" \
    --entrypoint cat "${image}" "/etc/letsencrypt/live/${cert}/privkey.pem" > /dev/null 2>&1; then
    fail "a container outside group ${group} can read the key"
fi
echo "ok - another container reads the key only as a member of group ${group}"
