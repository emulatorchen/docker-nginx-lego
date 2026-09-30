#!/usr/bin/env bash
# scripts/withdraw/issues.sh — take back the CVE issues TAG opened and commented.
#
# The release opens an issue for a finding only when no issue for it is open,
# and comments on the ones that are. So closing the issues it opened and
# deleting the comments it added puts the list back exactly as it was before
# the release, without having to scan the earlier release again.
#
# Env: TAG, REPO, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG REPO GH_TOKEN
is_release_tag "$TAG" || die "'${TAG}' is not a release tag"
marker=$(issue_marker)
prefix=$(comment_prefix)
failed=0

issues=$(gh issue list --repo "$REPO" --label security --state open --limit 200 \
           --json number,body) || die "cannot list the security issues"
while IFS= read -r n; do
  [ -n "$n" ] || continue
  if gh issue close "$n" --repo "$REPO" --reason "not planned" \
       --comment "Opened by release \`${TAG}\`, which has been withdrawn. No issue for this finding was open before that release." >/dev/null; then
    echo "#${n}: closed"
  else
    echo "::error::could not close #${n}"; failed=1
  fi
done < <(printf '%s' "$issues" | jq -r --arg m "$marker" '.[] | select(.body | contains($m)) | .number')

comments=$(gh api --paginate "repos/${REPO}/issues/comments?per_page=100" \
             --jq ".[] | select(.user.login == \"github-actions[bot]\") | select(.body | startswith(\"${prefix}\")) | .id") \
  || die "cannot list the issue comments"
while IFS= read -r id; do
  [ -n "$id" ] || continue
  if gh api -X DELETE "repos/${REPO}/issues/comments/${id}" >/dev/null 2>&1; then
    echo "deleted comment ${id}"
  else
    echo "::error::could not delete comment ${id}"; failed=1
  fi
done <<< "$comments"

exit "$failed"
