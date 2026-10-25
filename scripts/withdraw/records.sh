#!/usr/bin/env bash
# scripts/withdraw/records.sh — remove TAG's GitHub release and git tag.
#
# The Latest marker was set explicitly by the release, so it is handed back
# explicitly rather than left to GitHub.
#
# Env: TAG, PREV (may be empty), REPO, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG REPO GH_TOKEN
is_release_tag "$TAG" || die "'${TAG}' is not a release tag"

if was_latest=$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null); then :; else was_latest=""; fi
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release delete "$TAG" --repo "$REPO" --cleanup-tag --yes || die "could not delete release ${TAG}"
  echo "deleted release ${TAG} and its tag"
else
  echo "release ${TAG} not present"
fi
# A tag can outlive its release when an earlier attempt failed between the two.
if gh api "repos/${REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
  gh api -X DELETE "repos/${REPO}/git/refs/tags/${TAG}" >/dev/null || die "could not delete tag ${TAG}"
  echo "deleted tag ${TAG}"
fi
if [ "$was_latest" = "$TAG" ] && [ -n "${PREV:-}" ]; then
  gh release edit "$PREV" --repo "$REPO" --latest >/dev/null || die "could not mark ${PREV} as the latest release"
  echo "${PREV} is the latest release again"
fi
