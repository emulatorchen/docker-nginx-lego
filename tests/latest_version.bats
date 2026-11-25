#!/usr/bin/env bats
#
# .github/latest_version.sh tells the version checkers what the newest nginx,
# lego and upstream release is. When GitHub's answer is unusable it must print
# nothing and fail, so a checker can never open a PR or issue for an empty or
# "null" version (PR #320 bumped nginx "from 1.31.9 to" after an HTML reply).
# A fake gh stands in for the GitHub API, so these tests need no network.

SCRIPT="${BATS_TEST_DIRNAME}/../.github/latest_version.sh"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  local bin="${BATS_TEST_TMPDIR}/bin"
  REPLIES="${BATS_TEST_TMPDIR}/replies"
  mkdir -p "${bin}" "${REPLIES}"
  # gh api <path>: prints replies/<name> for the API it is asked about. While
  # the number in fail_times is above zero, each call fails and counts it down.
  cat > "${bin}/gh" <<EOF
#!/bin/bash
echo call >> "${BATS_TEST_TMPDIR}/calls"
if [ -s "${BATS_TEST_TMPDIR}/fail_times" ]; then
  n=\$(cat "${BATS_TEST_TMPDIR}/fail_times")
  if [ "\${n}" -gt 0 ]; then
    echo \$((n - 1)) > "${BATS_TEST_TMPDIR}/fail_times"
    echo "gh: HTTP 502: Bad Gateway" >&2
    exit 1
  fi
fi
case "\$2" in
  repos/nginx/nginx/tags*) cat "${REPLIES}/nginx" ;;
  repos/go-acme/lego/releases/latest) cat "${REPLIES}/lego" ;;
  repos/JonasAlfredsson/docker-nginx-certbot/releases/latest) cat "${REPLIES}/upstream" ;;
  *) echo "gh: HTTP 404: Not Found" >&2; exit 1 ;;
esac
EOF
  chmod +x "${bin}/gh"
  export PATH="${bin}:${PATH}"
  export LATEST_VERSION_RETRY_DELAY=0

  printf '%s' '[{"name":"release-1.31.9"},{"name":"release-1.31.10"},{"name":"release-1.30.9"},{"name":"njs-0.9.1"},{"name":"release-1.31.10-rc1"}]' \
    > "${REPLIES}/nginx"
  printf '%s' '{"tag_name":"v5.7.0","published_at":"2026-11-20T10:00:00Z"}' > "${REPLIES}/lego"
  printf '%s' '{"tag_name":"v3.4.0","published_at":"2026-11-20T10:00:00Z","html_url":"https://github.com/JonasAlfredsson/docker-nginx-certbot/releases/tag/v3.4.0"}' \
    > "${REPLIES}/upstream"
}

# stdout only: what a checker would capture with $(...).
stdout_of() {
  run bash -c "\"${SCRIPT}\" $* 2>/dev/null"
}

@test "nginx: the highest release tag wins in version order, not text order" {
  stdout_of nginx

  [ "${status}" -eq 0 ]
  [ "${output}" == "1.31.10" ]
}

@test "nginx: an HTML page instead of JSON prints nothing and fails, naming the API" {
  printf '<!DOCTYPE html>\n<html><body>Unicorn!</body></html>\n' > "${REPLIES}/nginx"

  stdout_of nginx
  [ "${status}" -eq 1 ]
  [ -z "${output}" ]

  run "${SCRIPT}" nginx
  grep -q "repos/nginx/nginx/tags" <<< "${output}"
}

@test "nginx: three failed calls give up, and nothing is printed" {
  echo 3 > "${BATS_TEST_TMPDIR}/fail_times"

  stdout_of nginx

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
  [ "$(wc -l < "${BATS_TEST_TMPDIR}/calls")" -eq 3 ]
}

@test "nginx: two failed calls and then an answer still give the version" {
  echo 2 > "${BATS_TEST_TMPDIR}/fail_times"

  stdout_of nginx

  [ "${status}" -eq 0 ]
  [ "${output}" == "1.31.10" ]
}

@test "nginx: a reply with no release tag fails" {
  printf '%s' '[{"name":"njs-0.9.1"},{"name":"release-1.31.10-rc1"}]' > "${REPLIES}/nginx"

  stdout_of nginx

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "lego: tag v5.7.0 gives 5.7.0" {
  stdout_of lego

  [ "${status}" -eq 0 ]
  [ "${output}" == "5.7.0" ]
}

@test "lego: a rate-limit reply without tag_name fails and never prints null" {
  printf '%s' '{"message":"API rate limit exceeded for 203.0.113.7.","documentation_url":"https://docs.github.com/rest"}' \
    > "${REPLIES}/lego"

  stdout_of lego

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "lego: a pre-release tag is not taken as a version" {
  printf '%s' '{"tag_name":"v5.7.0-rc.1"}' > "${REPLIES}/lego"

  stdout_of lego

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "upstream: prints the tag, the release date and the URL, tab separated" {
  stdout_of upstream

  [ "${status}" -eq 0 ]
  [ "${output}" == "$(printf 'v3.4.0\t2026-11-20\thttps://github.com/JonasAlfredsson/docker-nginx-certbot/releases/tag/v3.4.0')" ]
}

@test "upstream: a null tag fails instead of becoming a sync issue" {
  printf '%s' '{"tag_name":null,"published_at":null,"html_url":null}' > "${REPLIES}/upstream"

  stdout_of upstream

  [ "${status}" -eq 1 ]
  [ -z "${output}" ]
}

@test "no argument or an unknown one prints the usage" {
  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
  grep -q "usage" <<< "${output}"

  run "${SCRIPT}" postgres
  [ "${status}" -eq 2 ]
  grep -q "usage" <<< "${output}"
}
