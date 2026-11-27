#!/usr/bin/env bats
#
# .github/lego_pins.sh pins the lego binary the images install: every
# Dockerfile checks the tarball against ARG LEGO_SHA256_<ARCH>, and this script
# writes those pins only after gh has verified that lego's own release workflow
# attested the tarball. Fake gh and curl stand in for GitHub, so no network.

SCRIPT="${BATS_TEST_DIRNAME}/../.github/lego_pins.sh"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  local bin="${BATS_TEST_TMPDIR}/bin"
  ASSETS="${BATS_TEST_TMPDIR}/assets"
  mkdir -p "${bin}" "${ASSETS}"
  # curl -fsSL -o <file> <url>: copies assets/<basename of url>, or fails like a 404.
  cat > "${bin}/curl" <<EOF
#!/bin/bash
out=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift 2 ;; -*) shift ;; *) url="\$1"; shift ;; esac
done
src="${ASSETS}/\${url##*/}"
[ -f "\${src}" ] || { echo "curl: (22) The requested URL returned error: 404" >&2; exit 22; }
cp "\${src}" "\${out}"
EOF
  # gh attestation verify <file> ...: passes unless the file's name is listed in bad.
  cat > "${bin}/gh" <<EOF
#!/bin/bash
echo "\$*" >> "${BATS_TEST_TMPDIR}/gh-calls"
[ "\$1 \$2" = "attestation verify" ] || exit 2
if grep -qxF "\$(basename "\$3")" "${BATS_TEST_TMPDIR}/bad" 2>/dev/null; then
  echo "Error: no attestation matches" >&2; exit 1
fi
EOF
  chmod +x "${bin}/curl" "${bin}/gh"
  export PATH="${bin}:${PATH}"
  : > "${BATS_TEST_TMPDIR}/bad"

  for arch in amd64 386 arm64 armv7; do
    printf 'lego 5.7.0 for %s\n' "${arch}" > "${ASSETS}/lego_v5.7.0_linux_${arch}.tar.gz"
  done
  SRC="${BATS_TEST_TMPDIR}/src"
  mkdir -p "${SRC}"
  for f in Dockerfile Dockerfile-alpine; do
    printf 'FROM x\nARG LEGO_VERSION=5.6.0\nARG LEGO_SHA256_AMD64=old\nARG LEGO_SHA256_386=old\nARG LEGO_SHA256_ARM64=old\nARG LEGO_SHA256_ARMV7=old\nRUN true\n' > "${SRC}/${f}"
  done
}

sum() { sha256sum "${ASSETS}/lego_v5.7.0_linux_$1.tar.gz" | cut -d' ' -f1; }

@test "--update writes the version and every architecture's verified checksum" {
  run "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 0 ]
  for f in Dockerfile Dockerfile-alpine; do
    grep -qx "ARG LEGO_VERSION=5.7.0" "${SRC}/${f}"
    grep -qx "ARG LEGO_SHA256_AMD64=$(sum amd64)" "${SRC}/${f}"
    grep -qx "ARG LEGO_SHA256_386=$(sum 386)" "${SRC}/${f}"
    grep -qx "ARG LEGO_SHA256_ARM64=$(sum arm64)" "${SRC}/${f}"
    grep -qx "ARG LEGO_SHA256_ARMV7=$(sum armv7)" "${SRC}/${f}"
    grep -qx "RUN true" "${SRC}/${f}"
  done
}

@test "--update asks gh for lego's release workflow and the exact release tag" {
  "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" > /dev/null

  [ "$(wc -l < "${BATS_TEST_TMPDIR}/gh-calls")" -eq 4 ]
  while IFS= read -r call; do
    [[ "${call}" == *"--repo go-acme/lego"* ]]
    [[ "${call}" == *"--signer-workflow go-acme/lego/.github/workflows/release.yml"* ]]
    [[ "${call}" == *"--source-ref refs/tags/v5.7.0"* ]]
  done < "${BATS_TEST_TMPDIR}/gh-calls"
}

@test "--update refuses a release with one unattested tarball and changes nothing" {
  echo lego_v5.7.0_linux_arm64.tar.gz > "${BATS_TEST_TMPDIR}/bad"
  local before
  before="$(cat "${SRC}/Dockerfile")"

  run "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile"

  [ "${status}" -eq 1 ]
  grep -q "arm64" <<< "${output}"
  [ "$(cat "${SRC}/Dockerfile")" == "${before}" ]
}

@test "--update fails and changes nothing when a tarball cannot be downloaded" {
  rm "${ASSETS}/lego_v5.7.0_linux_386.tar.gz"
  local before
  before="$(cat "${SRC}/Dockerfile")"

  run "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile"

  [ "${status}" -eq 1 ]
  grep -q "386" <<< "${output}"
  [ "$(cat "${SRC}/Dockerfile")" == "${before}" ]
}

@test "--update refuses a Dockerfile that lacks one of the pin lines and changes nothing" {
  sed -i.bak '/^ARG LEGO_SHA256_ARMV7=/d' "${SRC}/Dockerfile-alpine"
  local before
  before="$(cat "${SRC}/Dockerfile")"

  run "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 1 ]
  grep -q "Dockerfile-alpine.*LEGO_SHA256_ARMV7" <<< "${output}"
  [ "$(cat "${SRC}/Dockerfile")" == "${before}" ]
}

@test "--check passes when the pins match lego's attested tarballs" {
  "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine" > /dev/null

  run "${SCRIPT}" --check "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 0 ]
}

@test "--check fails when a pin does not match the tarball" {
  "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" > /dev/null
  sed -i.bak "s/^ARG LEGO_SHA256_ARMV7=.*/ARG LEGO_SHA256_ARMV7=$(printf 'f%.0s' {1..64})/" "${SRC}/Dockerfile"

  run "${SCRIPT}" --check "${SRC}/Dockerfile"

  [ "${status}" -eq 1 ]
  grep -q "armv7" <<< "${output}"
}

@test "--check fails when the Dockerfiles disagree with each other" {
  "${SCRIPT}" --update 5.7.0 "${SRC}/Dockerfile" > /dev/null

  run "${SCRIPT}" --check "${SRC}/Dockerfile" "${SRC}/Dockerfile-alpine"

  [ "${status}" -eq 1 ]
  grep -q "disagree" <<< "${output}"
}

@test "a version that is not X.Y.Z, or no mode, prints the usage" {
  run "${SCRIPT}" --update '5.7.0;id' "${SRC}/Dockerfile"
  [ "${status}" -eq 2 ]
  grep -q "usage" <<< "${output}"

  run "${SCRIPT}"
  [ "${status}" -eq 2 ]
}
