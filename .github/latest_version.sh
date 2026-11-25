#!/bin/bash
# Prints the newest release of nginx, lego or the upstream project, as GitHub reports it.
#
# The version checkers open PRs and issues from this answer, so a reply that does not
# hold a well-formed version (an error page, a rate-limit message, a null tag) must
# never get through: it is retried, and after three tries the script prints nothing
# and fails. PR #320 bumped nginx "from 1.31.9 to" after exactly such a reply.
#
#   nginx     X.Y.Z of the highest release-X.Y.Z tag of nginx/nginx
#   lego      X.Y.Z of go-acme/lego's latest release (tag vX.Y.Z)
#   upstream  <tag> TAB <YYYY-MM-DD> TAB <release URL> of JonasAlfredsson/docker-nginx-certbot
#
# Exit status: 0 printed, 1 GitHub gave no usable answer, 2 usage.
# Uses `gh api`, so GH_TOKEN must be set; no jq, so it also runs in the bats container.
set -euo pipefail

UPSTREAM_REPO="JonasAlfredsson/docker-nginx-certbot"

usage() {
    echo "usage: latest_version.sh nginx|lego|upstream" >&2
    exit 2
}

# field <name> <json>: the string value of every "<name>": "<value>" pair, one per line.
field() {
    grep -oE "\"$1\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" <<< "$2" \
        | sed -E 's/^"[^"]*"[[:space:]]*:[[:space:]]*"(.*)"$/\1/' || true
}

nginx_version() {
    field name "$1" | sed -nE 's/^release-([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' | sort -V | tail -n 1
}

lego_version() {
    field tag_name "$1" | head -n 1 | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)$/\1/p'
}

upstream_release() {
    local tag date
    tag=$(field tag_name "$1" | head -n 1 | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)
    date=$(field published_at "$1" | head -n 1 | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    if [ -n "${tag}" ] && [ -n "${date}" ]; then
        printf '%s\t%s\thttps://github.com/%s/releases/tag/%s\n' "${tag}" "${date}" "${UPSTREAM_REPO}" "${tag}"
    fi
}

# parse <target> <reply>: the answer for <target>, or nothing when the reply has none.
parse() {
    case "$1" in
        nginx)    nginx_version "$2" ;;
        lego)     lego_version "$2" ;;
        upstream) upstream_release "$2" ;;
    esac
}

target="${1:-}"
case "${target}" in
    nginx)    path="repos/nginx/nginx/tags?per_page=100" ;;
    lego)     path="repos/go-acme/lego/releases/latest" ;;
    upstream) path="repos/${UPSTREAM_REPO}/releases/latest" ;;
    *) usage ;;
esac

for attempt in 1 2 3; do
    if reply=$(gh api "${path}" 2> /dev/null); then
        answer=$(parse "${target}" "${reply}")
        if [ -n "${answer}" ]; then
            printf '%s\n' "${answer}"
            exit 0
        fi
    fi
    if [ "${attempt}" -lt 3 ]; then
        sleep "${LATEST_VERSION_RETRY_DELAY:-10}"
    fi
done

echo "GitHub API ${path}: no usable release version after 3 attempts" >&2
exit 1
