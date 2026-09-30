#!/usr/bin/env bash
# scripts/withdraw/verify.sh — prove from outside that TAG is gone.
#
# Every place the release could have been published is read again, separately
# from the steps that removed it. The run fails if anything is still there, or
# if the release now live was disturbed. A green run means withdrawn, not "the
# steps ran".
#
# Each check is retried for a short while before it counts as a failure: Docker
# Hub can serve the old answer for a moment after a change. The table goes to
# the log as well as the summary.
#
# Env: TAG, DIGESTS, PREV, PREV_SAME (may be empty), KEPT (may be empty),
#      HUB_REPO, REPO, GH_TOKEN
#      STEPS  optional: one line naming each step's result, for the summary

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need TAG HUB_REPO REPO GH_TOKEN
is_release_tag "$TAG" || die "'${TAG}' is not a release tag"
LEGO=$(lego_of "$TAG")
TRIES="${TRIES:-6}"
fails=0

summary "## Withdrawal of \`${TAG}\`: verified from outside" ""
[ -z "${STEPS:-}" ] || summary "Steps: ${STEPS}" ""
summary "| Location | Observed | Result |" "|---|---|---|"

# check <label> <expected> <command...>: runs the command until it prints the
# expected value, or TRIES attempts 10 seconds apart have passed.
check() {
  local label=$1 want=$2 got i
  shift 2
  for ((i = 1; i <= TRIES; i++)); do
    got=$("$@" 2>/dev/null)
    [ "$got" = "$want" ] && break
    [ "$i" -lt "$TRIES" ] && sleep 10
  done
  if [ "$got" = "$want" ]; then
    summary "| ${label} | ${got} | ok |"; echo "ok    ${label}: ${got}"
  else
    summary "| ${label} | ${got} | **FAIL**, expected ${want} |"; echo "FAIL  ${label}: got [${got}] want [${want}]"
    fails=$((fails + 1))
  fi
}

present() { if "$@" >/dev/null 2>&1; then echo present; else echo absent; fi; }
open_issues() {
  local b
  b=$(gh issue list --repo "$REPO" --label security --state open --limit 200 --json body --jq '.[].body') || { echo unreadable; return; }
  printf '%s\n' "$b" | grep -cF "$(issue_marker)"
}
bot_comments() {
  local c
  c=$(gh api --paginate "repos/${REPO}/issues/comments?per_page=100" \
        --jq ".[] | select(.user.login == \"github-actions[bot]\") | select(.body | startswith(\"$(comment_prefix)\")) | .id") \
    || { echo unreadable; return; }
  printf '%s\n' "$c" | grep -c .
}
names() {  # moving tag, digest -> "still <TAG>" or "moved off"
  if [ "$(hub_digest "$1")" = "$2" ]; then echo "still ${TAG}"; else echo "moved off"; fi
}
page_state() { hub_page_decision | cut -f1; }
latest_release() { gh api "repos/${REPO}/releases/latest" --jq .tag_name; }
attestations() {
  local out
  if out=$(gh api "repos/${REPO}/attestations/$1" --jq '.attestations | length' 2>/dev/null); then
    echo "$out"
  elif printf '%s' "$out" | grep -q '"status":"404"'; then
    echo 0
  else
    echo unreadable
  fi
}

check "release ${TAG}" absent present gh release view "$TAG" --repo "$REPO"
check "git tag ${TAG}" absent present gh api "repos/${REPO}/git/ref/tags/${TAG}"
check "open CVE issues opened by ${TAG}" 0 open_issues
check "\"$(comment_prefix)\" comments" 0 bot_comments
check "Docker Hub page" leave page_state
for v in $VARIANTS; do
  s=$(suffix "$v"); d=$(digest_for "$v")
  case " ${KEPT:-} " in
    *" ${v} "*) check "${TAG}${s} (immutable, stays)" 200 hub_code "${TAG}${s}" ;;
    *)          check "${TAG}${s}" 404 hub_code "${TAG}${s}" ;;
  esac
  [ -n "$d" ] || continue
  check "latest${s}" "moved off" names "latest${s}" "$d"
  check "lego${LEGO}${s}" "moved off" names "lego${LEGO}${s}" "$d"
  case " ${KEPT:-} " in
    *" ${v} "*) ;;
    *) check "attestation records (${v})" 0 attestations "$d" ;;
  esac
done

# The release now live must be untouched.
if [ -n "${PREV:-}" ]; then
  check "release ${PREV} (live)" present present gh release view "$PREV" --repo "$REPO"
  check "\"Latest release\" marker" "$PREV" latest_release
  for v in $VARIANTS; do
    check "${PREV}$(suffix "$v")" 200 hub_code "${PREV}$(suffix "$v")"
  done
fi

if [ "$fails" -gt 0 ]; then
  die "${fails} location(s) still hold ${TAG}, or the live release was disturbed. Re-run once the cause is fixed; every step skips what is already gone."
fi
echo "${TAG} is withdrawn everywhere it can be"
