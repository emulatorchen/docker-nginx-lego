#!/usr/bin/env bash
# scripts/withdraw/latest.sh — move the moving tags back off TAG's images.
#
# For each variant, latest<sfx> goes back to PREV's image, and the short
# lego<L><sfx> tag goes back to PREV_SAME's (the newest remaining release of the
# same lego version). Moved back, not deleted: users stay on the previous good
# release, as if this one had never shipped. A tag is touched only while it
# still names this release's image; with nothing to go back to, it is deleted.
#
# Env: TAG, DIGESTS, PREV, PREV_SAME (may be empty), HUB_REPO,
#      HUB_USER, HUB_PAT (the registry token)

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG HUB_REPO HUB_USER HUB_PAT
is_release_tag "$TAG" || die "'${TAG}' is not a release tag"
LEGO=$(lego_of "$TAG")
hub="docker.io/${HUB_REPO}"
at() { docker buildx imagetools inspect "$1" --format '{{.Manifest.Digest}}' 2>/dev/null || true; }

user=$(printf '%s' "$HUB_USER" | tr -d '[:space:]')
printf '%s' "$HUB_PAT" | tr -d '[:space:]' | docker login docker.io -u "$user" --password-stdin >/dev/null \
  || die "could not log in to Docker Hub"
jwt=""

move_back() {  # moving tag, this release's digest, release to go back to (may be empty), variant suffix
  local t=$1 d=$2 to=$3 s=$4 want code
  if [ "$(hub_digest "$t")" != "$d" ]; then
    echo "${t} does not name ${TAG}, so it is left alone"
    return 0
  fi
  if [ -n "$to" ]; then
    want=$(at "${hub}:${to}${s}")
    [ -n "$want" ] || die "${hub}:${to}${s} does not resolve, so ${t} has nowhere to go back to"
    docker buildx imagetools create --tag "${hub}:${t}" "${hub}@${want}" || die "could not move ${t} back to ${to}"
    [ "$(at "${hub}:${t}")" = "$want" ] || die "${t} does not resolve to ${to} after moving it"
    echo "${t} -> ${to}${s} (${want})"
  else
    [ -n "$jwt" ] || jwt=$(HUB_SECRET="$HUB_PAT" hub_jwt)
    [ -n "$jwt" ] || die "could not authenticate to the Docker Hub API"
    code=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 -X DELETE \
             "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/${t}/" -H "Authorization: Bearer ${jwt}")
    case "$code" in
      20*|404) echo "${t} removed: nothing earlier to go back to" ;;
      *) die "deleting ${t} returned HTTP ${code}" ;;
    esac
  fi
}

for v in $VARIANTS; do
  s=$(suffix "$v"); d=$(digest_for "$v")
  if [ -z "$d" ]; then echo "${v}: no image for ${TAG}, so no tag can name it"; continue; fi
  is_digest "$d" || die "'${d}' is not a sha256 digest"
  move_back "latest${s}" "$d" "${PREV:-}" "$s"
  move_back "lego${LEGO}${s}" "$d" "${PREV_SAME:-}" "$s"
done
