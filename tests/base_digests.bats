#!/usr/bin/env bats
#
# .github/base_digests.sh keeps every 'FROM <image>:<tag>@sha256:<digest>' pin on
# the newest build of its tag. Upstream rebuilds a tag in place (same version,
# OS fixes), so the digest is the only thing that moves. A fake curl stands in
# for Docker Hub, so these tests need no network.

SCRIPT="${BATS_TEST_DIRNAME}/../.github/base_digests.sh"
OLD="sha256:$(printf 'a%.0s' {1..64})"
NEW="sha256:$(printf 'b%.0s' {1..64})"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  local bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${bin}"
  # Docker Hub as curl sees it: a token, then the digest each tag points at now.
  # nginx:1.31.8-alpine was rebuilt, nginx:1.31.8 was not, anything else is unknown.
  cat > "${bin}/curl" <<EOF
#!/bin/bash
case "\$*" in
  *auth.docker.io*) echo '{"token":"fake-token","access_token":"fake-token"}' ;;
  *library/nginx/manifests/1.31.8-alpine*) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: ${NEW}\r\n\r\n' ;;
  *library/nginx/manifests/1.31.8*) printf 'HTTP/1.1 200 OK\r\ndocker-content-digest: ${OLD}\r\n\r\n' ;;
  *library/alpine/manifests/odd*) printf 'HTTP/1.1 200 OK\r\nDocker-Content-Digest: sha256:abc|x\r\n\r\n' ;;
  *) echo "curl: (22) The requested URL returned error: 404" >&2; exit 22 ;;
esac
EOF
  chmod +x "${bin}/curl"
  export PATH="${bin}:${PATH}"

  SRC="${BATS_TEST_TMPDIR}/src"
  mkdir -p "${SRC}"
  printf 'FROM nginx:1.31.8@%s\nRUN true\n' "${OLD}" > "${SRC}/Dockerfile"
  printf 'FROM nginx:1.31.8-alpine@%s\nRUN true\n' "${OLD}" > "${SRC}/Dockerfile-alpine"
}

@test "--check lists only the pin whose tag was rebuilt, and exits 1" {
  run "${SCRIPT}" --check "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 1 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"Dockerfile-alpine nginx:1.31.8-alpine ${OLD} ${NEW}" ]]
}

@test "--check changes nothing" {
  local before
  before="$(cat "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine")"

  run "${SCRIPT}" --check "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "$(cat "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine")" == "${before}" ]
}

@test "--update re-pins only the rebuilt tag and keeps the rest of the file" {
  run "${SCRIPT}" --update "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 0 ]
  [ "$(cat "${SRC}/Dockerfile-alpine")" == "$(printf 'FROM nginx:1.31.8-alpine@%s\nRUN true' "${NEW}")" ]
  [ "$(cat "${SRC}/Dockerfile")" == "$(printf 'FROM nginx:1.31.8@%s\nRUN true' "${OLD}")" ]
}

@test "--check passes once every pin is current" {
  "${SCRIPT}" --update "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine" > /dev/null

  run "${SCRIPT}" --check "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}

@test "a tag that cannot be resolved fails loudly instead of being skipped" {
  printf 'FROM ubuntu:24.04@%s\n' "${OLD}" > "${SRC}/Dockerfile-ubuntu"

  run "${SCRIPT}" --check "${SRC}/Dockerfile-ubuntu"

  [ "${status}" -ne 0 ]
  [ "${status}" -ne 1 ]
  grep -q "cannot resolve ubuntu:24.04" <<< "${output}"
}

@test "an answer that is not a sha256 digest is refused and changes nothing" {
  printf 'FROM alpine:odd@%s\n' "${OLD}" > "${SRC}/Dockerfile-odd"

  run "${SCRIPT}" --update "${SRC}/Dockerfile-odd"

  [ "${status}" -eq 3 ]
  grep -q "not a sha256 digest" <<< "${output}"
  [ "$(cat "${SRC}/Dockerfile-odd")" == "FROM alpine:odd@${OLD}" ]
}

@test "a FROM line without a digest pin is left alone" {
  printf 'FROM alpine:3.20\nRUN true\n' > "${SRC}/Dockerfile-unpinned"

  run "${SCRIPT}" --update "${SRC}/Dockerfile-unpinned"

  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
  [ "$(cat "${SRC}/Dockerfile-unpinned")" == "$(printf 'FROM alpine:3.20\nRUN true')" ]
}

@test "an unknown option prints the usage" {
  run "${SCRIPT}" --frobnicate

  [ "${status}" -eq 2 ]
  grep -q "usage" <<< "${output}"
}
