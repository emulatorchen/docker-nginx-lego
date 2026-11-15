#!/bin/bash
# Keeps every base image pinned in the Dockerfiles on the newest build of its tag.
#
# Each Dockerfile pins its base as 'FROM <image>:<tag>@sha256:<digest>'. Upstream
# rebuilds a tag in place for OS fixes (same nginx or Ubuntu version), so only the
# digest moves and nothing else notices. --check prints every pin whose tag now
# points at another digest; --update also rewrites those pins.
#
# One line per stale pin: <file> <image>:<tag> <pinned digest> <current digest>
# Exit status: 0 current (or updated), 1 stale (--check), 2 usage, 3 a tag did not resolve.
#
# Usage: base_digests.sh --check|--update [Dockerfile...]   (default: src/Dockerfile*)
set -euo pipefail

usage() {
    echo "usage: base_digests.sh --check|--update [Dockerfile...]" >&2
    exit 2
}

# current_digest <image> <tag>: the digest Docker Hub serves for <image>:<tag> now.
# A HEAD request returns it in Docker-Content-Digest without downloading anything,
# and does not count against the pull rate limit.
current_digest() {
    local repo="$1" tag="$2" token
    case "${repo}" in
        */*) ;;
        *) repo="library/${repo}" ;;
    esac
    token=$(curl -fsS --retry 3 \
        "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
        | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
    [ -n "${token}" ] || return 1
    curl -fsSI --retry 3 \
        -H "Authorization: Bearer ${token}" \
        -H "Accept: application/vnd.oci.image.index.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.list.v2+json" \
        -H "Accept: application/vnd.oci.image.manifest.v1+json" \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        "https://registry-1.docker.io/v2/${repo}/manifests/${tag}" \
        | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
}

mode="${1:-}"
case "${mode}" in
    --check|--update) shift ;;
    *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -eq 0 ]; then
    set -- "${root}/src/Dockerfile" "${root}/src/Dockerfile-alpine" "${root}/src/Dockerfile-ubuntu"
fi

stale=0
for file in "$@"; do
    pins=$(sed -n 's/^FROM[[:space:]][[:space:]]*\([^[:space:]]*:[^[:space:]@]*@sha256:[0-9a-f]\{64\}\).*/\1/p' "${file}")
    for pin in ${pins}; do
        image_tag="${pin%@*}"
        pinned="${pin#*@}"
        if ! current=$(current_digest "${image_tag%:*}" "${image_tag##*:}") || [ -z "${current}" ]; then
            echo "cannot resolve ${image_tag}" >&2
            exit 3
        fi
        # It goes into a sed expression and a Dockerfile, so accept exactly a digest.
        if ! [[ "${current}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
            echo "cannot resolve ${image_tag}: the registry answered '${current}', not a sha256 digest" >&2
            exit 3
        fi
        if [ "${current}" = "${pinned}" ]; then
            continue
        fi
        echo "${file#"${root}"/} ${image_tag} ${pinned} ${current}"
        stale=1
        if [ "${mode}" = --update ]; then
            # -i.bak works with both GNU and BSD sed.
            sed -i.bak "s|${image_tag}@${pinned}|${image_tag}@${current}|" "${file}"
            rm -f "${file}.bak"
        fi
    done
done

if [ "${mode}" = --check ]; then
    exit "${stale}"
fi
