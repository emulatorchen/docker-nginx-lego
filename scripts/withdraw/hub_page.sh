#!/usr/bin/env bash
# scripts/withdraw/hub_page.sh — put the Docker Hub page back to the live release.
#
# Restored only while it still shows what TAG published and that differs from
# PREV's page (see hub_page_decision in lib.sh). It is then written from the
# page source as it was in PREV, and read back.
#
# Env: TAG, PREV (may be empty), HUB_REPO, REPO, GH_TOKEN,
#      HUB_USER, HUB_PW (the account password)

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG HUB_REPO REPO
IFS=$'\t' read -r decision reason < <(hub_page_decision)
if [ "$decision" != "restore" ]; then
  echo "the Docker Hub page is left alone: ${reason}"
  exit 0
fi
page=$(mktemp)
expected_page "$page" || die "cannot read the page source of ${PREV}"
# dockerhub_page.sh writes the page and reads it back byte for byte.
./scripts/dockerhub_page.sh "$HUB_REPO" "$page" || die "could not restore the Docker Hub page"
echo "Docker Hub page restored to ${PREV}"
