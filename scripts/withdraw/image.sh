#!/usr/bin/env bash
# scripts/withdraw/image.sh — remove TAG's version tags, where anyone can.
#
# The version tags lego<L>-nginx<N>[-r<R>]<sfx> are covered by the repository's
# tag-immutability rule: they can be neither overwritten nor deleted, by anyone.
# So they are checked, not attempted. An immutable tag is reported as staying,
# and the attestation records that prove its image stay with it.
#
# A release rolling itself back never has these tags: it creates them last.
#
# Env:     TAG, HUB_REPO, HUB_USER, HUB_PAT (the registry token)
# Outputs: kept  the variants whose version tag stays, space-separated

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG HUB_REPO
is_release_tag "$TAG" || die "'${TAG}' is not a release tag"
kept=""; jwt=""
for v in $VARIANTS; do
  t="${TAG}$(suffix "$v")"
  case "$(hub_code "$t")" in
    404) echo "${t} does not exist, so there is nothing to remove"; continue ;;
    200) ;;
    *)   die "could not check ${t}" ;;
  esac
  rule=$(immutable_rule "$t")
  if [ -n "$rule" ]; then
    warn "${t} is immutable (rule ${rule}) and nobody can remove it. It stays, with its attestation records."
    summary "### \`${HUB_REPO}:${t}\` stays" "" \
      "The tag-immutability rule \`${rule}\` stops deletion as well as overwrite." ""
    kept="${kept:+${kept} }${v}"
    continue
  fi
  need HUB_USER HUB_PAT
  [ -n "$jwt" ] || jwt=$(HUB_SECRET="$HUB_PAT" hub_jwt)
  [ -n "$jwt" ] || die "could not authenticate to the Docker Hub API"
  code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 -X DELETE \
           "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/${t}/" -H "Authorization: Bearer ${jwt}")
  case "$code" in
    20*|404) echo "deleted ${t} (HTTP ${code})" ;;
    *) die "deleting ${t} returned HTTP ${code}" ;;
  esac
done
output kept "$kept"
