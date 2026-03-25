#!/usr/bin/env bash
set -euo pipefail

DOCKERFILE="src/Dockerfile"

lego_version=$(grep -m1 '^ARG LEGO_VERSION=' "$DOCKERFILE" | cut -d= -f2)
nginx_version=$(grep -m1 '^FROM nginx:' "$DOCKERFILE" | sed 's/FROM nginx://')

if [ -z "$lego_version" ] || [ -z "$nginx_version" ]; then
    echo "ERROR: could not extract versions from $DOCKERFILE" >&2
    exit 1
fi

revision=""
if [ "${1:-}" = "-r" ] && [ -n "${2:-}" ]; then
    revision="-r${2}"
fi

tag="lego${lego_version}-nginx${nginx_version}${revision}"

echo "lego:  $lego_version"
echo "nginx: $nginx_version"
echo "tag:   $tag"
echo ""
read -r -p "Push tag '$tag' to origin? [y/N] " answer
[ "${answer}" = "y" ] || [ "${answer}" = "Y" ] || { echo "Aborted."; exit 0; }

git tag "$tag"
git push origin "$tag"

echo "Creating GitHub release..."
prev_tag=$(git tag --sort=-creatordate | grep -v "^${tag}$" | head -1)
if [ -n "$prev_tag" ]; then
    gh release create "$tag" \
        --title "$tag" \
        --generate-notes \
        --latest
else
    gh release create "$tag" \
        --title "$tag" \
        --notes "**Components:** lego ${lego_version} · nginx ${nginx_version}

**Docker Hub:** \`emulator/docker-nginx-lego:${tag}\`" \
        --latest
fi

echo "Done."
echo "Release:  https://github.com/emulatorchen/docker-nginx-certbot/releases/tag/$tag"
echo "Actions:  https://github.com/emulatorchen/docker-nginx-certbot/actions"
