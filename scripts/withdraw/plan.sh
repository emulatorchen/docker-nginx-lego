#!/usr/bin/env bash
# scripts/withdraw/plan.sh — find everything TAG left behind, and list it.
#
# Runs before the approval and changes nothing. The person approving is shown
# what exists and what will happen to it, not asked to approve a tag name.
#
# Env:     TAG, HUB_REPO, REPO, GH_TOKEN
#          DIGESTS  optional "debian=…,alpine=…,ubuntu=…"; the release passes
#                   the digests it pushed, a manual withdrawal reads them from
#                   the release's version tags
# Outputs: tag hub_repo digests prev prev_same found

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG HUB_REPO REPO GH_TOKEN
is_release_tag "$TAG" || die "'${TAG}' is not a release tag (lego<L>-nginx<N>[-r<R>])"
printf '%s' "$HUB_REPO" | grep -qE '^[a-z0-9][a-z0-9._-]*/[a-z0-9][a-z0-9._-]*$' || die "'${HUB_REPO}' is not owner/name"
LEGO=$(lego_of "$TAG")

# Digests: what the release pushed, or what its version tags name.
digests=""
for v in $VARIANTS; do
  d=$(digest_for "$v")
  [ -n "$d" ] || d=$(hub_digest "${TAG}$(suffix "$v")")
  if [ -n "$d" ] && ! is_digest "$d"; then die "'${d}' is not a sha256 digest"; fi
  digests="${digests:+${digests},}${v}=${d}"
done
DIGESTS="$digests"

# The release live once this one is gone, and the newest one sharing its lego
# version (what the short lego<L> tags go back to). A failed listing stops here:
# read as "no earlier release", it would delete latest instead of moving it back.
others=$(other_releases) || others=""
gh release list --repo "$REPO" --limit 1 >/dev/null || die "cannot list the releases"
PREV=$(printf '%s\n' "$others" | head -1)
prev_same=$(printf '%s\n' "$others" | grep -E "^lego${LEGO//./\\.}-nginx" | head -1)

found=0
summary "## Withdrawing \`${TAG}\`" "" \
  "Undone in this order, the reverse of how it was published, so nothing is ever" \
  "advertised after the thing it points at is gone." "" \
  "| # | What | Now | Action |" "|---|---|---|---|"
row() { summary "| $1 | $2 | $3 | $4 |"; }

# 0. What describes the release: the Docker Hub page and the CVE issues.
IFS=$'\t' read -r decision reason < <(hub_page_decision)
if [ "$decision" = "restore" ]; then
  row 0 "Docker Hub page" "${reason}" "**restore** the page as it was in ${PREV}"; found=1
else
  row 0 "Docker Hub page" "${reason}" "left alone"
fi
marker=$(issue_marker)
if n=$(gh issue list --repo "$REPO" --label security --state open --limit 200 --json body \
         --jq "[.[] | select(.body | contains(\"${marker//\"/\\\"}\"))] | length"); then
  row 0 "CVE issues opened by ${TAG}" "${n} open" "**close**: none of them was open before this release"
  [ "$n" = "0" ] || found=1
else
  row 0 "CVE issues opened by ${TAG}" "unreadable" "checked again when the step runs"
fi
row 0 "\"$(comment_prefix)\" comments" "-" "**delete**"

# 1. The moving tags: latest and the short lego<L> tag of each variant.
for v in $VARIANTS; do
  s=$(suffix "$v"); d=$(digest_for "$v")
  [ -n "$d" ] || continue
  if [ "$(hub_digest "latest${s}")" = "$d" ]; then
    row 1 "\`latest${s}\`" "points at ${TAG}" "**move back** to ${PREV:-nothing: no earlier release, so it is deleted}"; found=1
  fi
  if [ "$(hub_digest "lego${LEGO}${s}")" = "$d" ]; then
    row 1 "\`lego${LEGO}${s}\`" "points at ${TAG}" "**move back** to ${prev_same:-nothing: no earlier lego ${LEGO} release, so it is deleted}"; found=1
  fi
done

# 2. The GitHub release, its git tag and the Latest marker.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  row 2 "release \`${TAG}\`" "published" "**delete**, with its git tag"; found=1
elif gh api "repos/${REPO}/git/ref/tags/${TAG}" >/dev/null 2>&1; then
  row 2 "git tag \`${TAG}\`" "exists without a release" "**delete**"; found=1
else
  row 2 "release \`${TAG}\`" "absent" "nothing to do"
fi
row 2 "\"Latest release\" marker" "-" "**moves to** ${PREV:-nothing, no earlier release}"

# 3 and 4. The version tags, and the proof of the images.
for v in $VARIANTS; do
  t="${TAG}$(suffix "$v")"; d=$(digest_for "$v")
  case "$(hub_code "$t")" in
    404) row 3 "\`${t}\`" "no version tag" "nothing to do" ;;
    200)
      rule=$(immutable_rule "$t")
      if [ -n "$rule" ]; then
        row 3 "\`${t}\`" "immutable (rule \`${rule}\`)" "**stays**: Docker Hub lets no one delete it"
      else
        row 3 "\`${t}\`" "published" "**delete**"; found=1
      fi ;;
    *) row 3 "\`${t}\`" "unreadable" "checked again when the step runs" ;;
  esac
  if [ -n "$d" ]; then
    row 4 "attestation records (${v})" "for \`${d}\`" "**delete**, unless the version tag stays"
    found=1
  fi
done

summary "" "Nobody can undo the Sigstore transparency-log entry. Content pushed by digest" \
  "without a tag stays on Docker Hub, unnamed, until Docker Hub cleans it up." ""
if [ "$found" = "1" ]; then
  summary "**The next approval undoes everything marked above. It publishes nothing.**" "" \
    "Review deployments → release-approval → Approve and deploy."
else
  summary "Nothing from ${TAG} is published. There is nothing to withdraw."
fi

output tag "$TAG"
output hub_repo "$HUB_REPO"
output digests "$DIGESTS"
output prev "$PREV"
output prev_same "$prev_same"
output found "$found"
