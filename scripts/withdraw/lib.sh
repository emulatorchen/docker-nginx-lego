# shellcheck shell=bash
# scripts/withdraw/lib.sh — shared by every withdrawal step.
#
# The steps run in two places: as the rollback jobs of a release that failed
# before its immutable Docker Hub tags were created, in that same run, and as
# the manual "Withdraw a release" workflow. One copy of the logic, two callers.
# The workflows only decide which environment and which permissions each step
# gets.
#
# Every step is idempotent: run it twice and the second run finds nothing to do.
# Every gh call is judged by its exit status, because on an error gh prints the
# error body to stdout, and a fallback inside $( ) would keep that text as if it
# were the answer.
#
# A release is named by its tag, lego<L>-nginx<N>[-r<R>], and publishes three
# variants. Each variant's Docker Hub tags carry the variant's suffix:
#
#   debian  ""        alpine  "-alpine"        ubuntu  "-ubuntu"

set -uo pipefail

# SC2034: used by the scripts that source this file, not here.
# shellcheck disable=SC2034
VARIANTS="debian alpine ubuntu"

die()  { echo "::error::$*" >&2; exit 1; }
warn() { echo "::warning::$*"; }

# Required environment, by name.
need() { local v; for v in "$@"; do [ -n "${!v:-}" ] || die "$v is not set"; done; }

is_digest() { printf '%s' "$1" | grep -qE '^sha256:[0-9a-f]{64}$'; }

# A release tag. Anchored, so it is safe in a URL, a grep and a shell word.
is_release_tag() { printf '%s' "$1" | grep -qE '^lego[0-9][0-9A-Za-z.]*-nginx[0-9][0-9.]*(-r[0-9]+)?$'; }

suffix() {  # variant -> tag suffix
  case "$1" in
    debian) printf '' ;;
    alpine) printf -- '-alpine' ;;
    ubuntu) printf -- '-ubuntu' ;;
    *) die "unknown variant $1" ;;
  esac
}

# lego<L>-nginx<N>[-r<R>] -> the lego version L.
lego_of() { printf '%s' "$1" | sed -E 's/^lego([^-]+)-nginx.*/\1/'; }

# DIGESTS is "debian=sha256:…,alpine=sha256:…,ubuntu=sha256:…". Empty when unknown.
digest_for() {  # variant
  printf '%s' "${DIGESTS:-}" | tr ',' '\n' | sed -n "s/^$1=//p" | head -1
}

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then printf '%s\n' "$@" >> "$GITHUB_STEP_SUMMARY"; else printf '%s\n' "$@"; fi
}
output() {  # key value
  if [ -n "${GITHUB_OUTPUT:-}" ]; then printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"; else printf 'output %s=%s\n' "$1" "$2"; fi
}

# The digest a Docker Hub tag names, from the public API, or nothing.
hub_digest() {  # tag
  curl -s --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/$1/" \
    | jq -r '.digest // empty' 2>/dev/null
}
hub_code() {  # tag -> HTTP status of the tag
  curl -s -o /dev/null -w '%{http_code}' --retry 3 --max-time 30 \
    "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/$1/"
}

# A Docker Hub web-API token from HUB_USER and HUB_SECRET (a password or a PAT).
# Whitespace is trimmed, since a pasted newline breaks the JSON body in a way the
# API reports as nothing useful. Case is left exactly as stored.
hub_jwt() {
  local u p body
  u=$(printf '%s' "${HUB_USER:-}" | tr -d '[:space:]')
  p=$(printf '%s' "${HUB_SECRET:-}" | tr -d '[:space:]')
  if [ -z "$u" ] || [ -z "$p" ]; then die "Docker Hub username or credential is empty"; fi
  body=$(jq -n --arg u "$u" --arg p "$p" '{username:$u, password:$p}')
  curl -sf --retry 3 --max-time 30 -X POST "https://hub.docker.com/v2/users/login" \
    -H "Content-Type: application/json" -d "$body" | jq -r '.token // empty'
}

# The live Docker Hub page, from the public API. Fails when it cannot be read.
hub_page_live() { curl -sf --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/" | jq -er '.full_description // ""'; }

# The published releases, newest first, excluding TAG. Fails when it cannot list.
other_releases() {
  gh release list --repo "$REPO" --exclude-drafts --exclude-pre-releases --limit 100 \
    --json tagName,createdAt --jq 'sort_by(.createdAt) | reverse | .[].tagName' \
    | grep -E '^lego[0-9]' | grep -vxF "$TAG"
}

# Whether a tag's immutability rule covers it, from the public settings.
immutable_rule() {  # tag -> the matching rule, or nothing
  local settings rule
  settings=$(curl -sf --retry 3 --max-time 30 "https://hub.docker.com/v2/repositories/${HUB_REPO}/" \
               | jq -c '.immutable_tags_settings // {}') || die "could not read the immutability settings"
  [ "$(printf '%s' "$settings" | jq -r '.enabled // false')" = "true" ] || return 0
  # Docker Hub rules are RE2; the one this project uses is a plain anchored
  # pattern that ERE reads the same way.
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    if printf '%s' "$1" | grep -qE -- "$rule"; then printf '%s' "$rule"; return 0; fi
  done < <(printf '%s' "$settings" | jq -r '.rules[]?')
}

# The issue body line and comment prefix the release writes for TAG. The
# backticks are markdown code spans.
# shellcheck disable=SC2016
issue_marker()   { printf '**Detected in release:** `%s`' "$TAG"; }
# shellcheck disable=SC2016
comment_prefix() { printf 'Last seen in release `%s`' "$TAG"; }

# The Docker Hub page as it should read once TAG is gone: the page source as it
# was in PREV, the release live afterwards. Written to $1. Fails without PREV.
expected_page() {  # out-file
  [ -n "${PREV:-}" ] || return 1
  git show "${PREV}:docs/dockerhub_description.md" > "$1" 2>/dev/null
}

# The page source TAG published: from its git tag when it exists, else from this
# checkout (a release rolling itself back has not created its tag yet).
released_page() {  # out-file
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    git show "${TAG}:docs/dockerhub_description.md" > "$1" 2>/dev/null
  else
    cp docs/dockerhub_description.md "$1"
  fi
}

# Whether the Docker Hub page has to be put back. Prints "restore" or "leave",
# then a tab and the reason. The page is restored only while it still shows what
# TAG published and that differs from PREV's: a page a later release has
# written since is never touched, and with no earlier release there is nothing
# to go back to.
hub_page_decision() {
  local live exp rel
  live=$(mktemp); exp=$(mktemp); rel=$(mktemp)
  if ! hub_page_live > "$live"; then printf 'leave\tthe page could not be read\n'; return 0; fi
  if ! expected_page "$exp"; then printf 'leave\tno earlier release to go back to\n'; return 0; fi
  released_page "$rel" || { printf 'leave\tthe released page source could not be read\n'; return 0; }
  # $( ) on both sides: Docker Hub drops the trailing newline.
  if [ "$(cat "$live")" = "$(cat "$exp")" ]; then
    printf 'leave\tit already shows %s\n' "$PREV"
  elif [ "$(cat "$live")" = "$(cat "$rel")" ]; then
    printf 'restore\tit shows what %s published\n' "$TAG"
  else
    printf 'leave\ta later change wrote it\n'
  fi
  rm -f "$live" "$exp" "$rel"
}
