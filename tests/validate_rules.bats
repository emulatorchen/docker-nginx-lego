#!/usr/bin/env bats
#
# scripts/validate.sh is the supply-chain gate for .github/workflows/. These
# tests feed it small fixture workflows and check the rules that keep third-party
# images, triggers and token permissions out of reach of a change that should not
# have them. Only the rule under test is asserted; actionlint and zizmor are not
# installed in the test container, so their sections fail on their own here.

VALIDATE="${BATS_TEST_DIRNAME}/../scripts/validate.sh"
PIN="sha256:$(printf 'a%.0s' {1..64})"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  ROOT="${BATS_TEST_TMPDIR}/repo"
  WF="${ROOT}/.github/workflows"
  mkdir -p "${WF}" "${BATS_TEST_TMPDIR}/tools"
  export VALIDATE_ROOT="${ROOT}"
  export TOOLS_DIR="${BATS_TEST_TMPDIR}/tools"
}

# job <name> <steps...>: a minimal schedule-triggered workflow with one job.
workflow() {
  local file="$1"; shift
  {
    printf 'name: "%s"\non:\n  workflow_dispatch:\npermissions:\n  contents: read\nconcurrency:\n  group: x\njobs:\n  build:\n    runs-on: ubuntu-latest\n    permissions:\n      contents: read\n    steps:\n' "${file}"
    printf '%s\n' "$@"
  } > "${WF}/${file}"
}

run_gate() {
  run bash "${VALIDATE}"
}

@test "setup-qemu without an image is refused" {
  workflow ci.yml \
    '      - uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0'
  run_gate
  grep -qE "FAIL  ci.yml:[0-9]+ setup-qemu without a digest-pinned image" <<< "${output}"
}

@test "setup-qemu with a tag-only image is refused, a digest-pinned one passes" {
  workflow tag.yml \
    '      - uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0' \
    '        with:' \
    '          image: docker.io/tonistiigi/binfmt:qemu-v9.2.2'
  workflow pinned.yml \
    '      - uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0' \
    '        with:' \
    "          image: docker.io/tonistiigi/binfmt:qemu-v9.2.2@${PIN}"
  run_gate
  grep -qE "FAIL  tag.yml:[0-9]+ setup-qemu without a digest-pinned image" <<< "${output}"
  grep -qE "ok    pinned.yml:[0-9]+ setup-qemu image pinned" <<< "${output}"
}

@test "setup-buildx without a pinned buildkit image is refused" {
  workflow none.yml \
    '      - name: Set up Docker Buildx' \
    '        uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0'
  workflow tag.yml \
    '      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0' \
    '        with:' \
    '          driver-opts: image=moby/buildkit:v0.26.2'
  run_gate
  grep -qE "FAIL  none.yml:[0-9]+ setup-buildx without a digest-pinned buildkit image" <<< "${output}"
  grep -qE "FAIL  tag.yml:[0-9]+ setup-buildx without a digest-pinned buildkit image" <<< "${output}"
}

@test "setup-buildx with a digest-pinned buildkit image passes, also as a block" {
  workflow inline.yml \
    '      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0' \
    '        with:' \
    "          driver-opts: image=moby/buildkit:v0.26.2@${PIN}"
  workflow block.yml \
    '      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0' \
    '        with:' \
    '          driver-opts: |' \
    "            image=moby/buildkit:v0.26.2@${PIN}" \
    '            network=host' \
    '      - run: echo next'
  run_gate
  grep -qE "ok    inline.yml:[0-9]+ setup-buildx buildkit pinned" <<< "${output}"
  grep -qE "ok    block.yml:[0-9]+ setup-buildx buildkit pinned" <<< "${output}"
}

@test "release and withdraw workflows accept no trigger but workflow_dispatch" {
  printf 'on:\n  workflow_dispatch:\n  workflow_run:\n    workflows: [x]\njobs: {}\n' > "${WF}/release.yml"
  printf 'on:\n  pull_request_target:\n  workflow_dispatch:\njobs: {}\n' > "${WF}/withdraw_release.yml"
  run_gate
  grep -qE "FAIL  release.yml: triggers other than workflow_dispatch: workflow_run" <<< "${output}"
  grep -qE "FAIL  withdraw_release.yml: triggers other than workflow_dispatch: pull_request_target" <<< "${output}"
}

@test "a release workflow with only workflow_dispatch passes the trigger rule" {
  printf 'on:\n  workflow_dispatch:\n    inputs:\n      notes:\n        type: string\njobs: {}\n' > "${WF}/release.yml"
  run_gate
  grep -qE "ok    release.yml: workflow_dispatch only" <<< "${output}"
}

@test "a pull_request workflow may not ask for id-token, attestations or contents write" {
  printf 'on:\n  pull_request:\njobs:\n  a:\n    permissions:\n      id-token: write\n  b:\n    permissions:\n      "attestations": write\n  c:\n    permissions:\n      contents: write\n' > "${WF}/pr.yml"
  printf 'on:\n  schedule:\n    - cron: "0 0 * * 1"\njobs:\n  a:\n    permissions:\n      contents: write\n' > "${WF}/cron.yml"
  run_gate
  grep -qE "FAIL  pr.yml:6 PR-triggered job asks for id-token: write" <<< "${output}"
  grep -qE "FAIL  pr.yml:9 PR-triggered job asks for attestations: write" <<< "${output}"
  grep -qE "FAIL  pr.yml:12 PR-triggered job asks for contents: write" <<< "${output}"
  ! grep -qE "FAIL  cron.yml.*asks for" <<< "${output}"
}

@test "zizmor runs without the repository's config, and a crash fails the gate" {
  cat > "${TOOLS_DIR}/zizmor" <<EOF
#!/bin/bash
echo "\$*" > "${BATS_TEST_TMPDIR}/zizmor-args"
exit 1
EOF
  chmod +x "${TOOLS_DIR}/zizmor"
  workflow ci.yml '      - run: echo hi'
  run_gate
  grep -q -- "--no-config" "${BATS_TEST_TMPDIR}/zizmor-args"
  grep -qE "FAIL  zizmor did not complete \(exit 1\)" <<< "${output}"
}

@test "zizmor reporting findings is judged by the findings, not as a crash" {
  cat > "${TOOLS_DIR}/zizmor" <<'EOF'
#!/bin/bash
echo "warning[unpinned-images]: something"
exit 12
EOF
  chmod +x "${TOOLS_DIR}/zizmor"
  workflow ci.yml '      - run: echo hi'
  run_gate
  ! grep -qE "zizmor did not complete" <<< "${output}"
  grep -qE "warning-level findings" <<< "${output}"
}

# ── forms that once slipped past the rules: each must still be refused ───────

@test "a quoted uses: key does not hide an unpinned setup-qemu" {
  workflow q.yml \
    '      - "uses": docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0'
  run_gate
  grep -qE "FAIL  q.yml:[0-9]+ setup-qemu without a digest-pinned image" <<< "${output}"
}

@test "a pinned image in a comment does not count" {
  workflow c.yml \
    '      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0' \
    "        # was: image=moby/buildkit:v0.26.2@${PIN}"
  run_gate
  grep -qE "FAIL  c.yml:[0-9]+ setup-buildx without a digest-pinned buildkit image" <<< "${output}"
}

@test "an image under env: is not an input and does not count" {
  workflow e.yml \
    '      - uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0' \
    '        env:' \
    "          image: docker.io/tonistiigi/binfmt:x@${PIN}"
  run_gate
  grep -qE "FAIL  e.yml:[0-9]+ setup-qemu without a digest-pinned image" <<< "${output}"
}

@test "the next job's pinned container image does not count for the last step" {
  {
    printf 'on:\n  workflow_dispatch:\njobs:\n  a:\n    runs-on: x\n    steps:\n'
    printf '      - uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8 # v4.2.0\n'
    printf '  b:\n    runs-on: x\n    container:\n      image: alpine@%s\n    steps:\n      - run: true\n' "${PIN}"
  } > "${WF}/last.yml"
  run_gate
  grep -qE "FAIL  last.yml:[0-9]+ setup-qemu without a digest-pinned image" <<< "${output}"
}

@test "one unpinned image= in driver-opts fails even next to a pinned one" {
  workflow two.yml \
    '      - uses: docker/setup-buildx-action@bb05f3f5519dd87d3ba754cc423b652a5edd6d2c # v4.2.0' \
    '        with:' \
    '          driver-opts: |' \
    "            image=moby/buildkit:v0.26.2@${PIN}" \
    '            image=moby/buildkit:latest'
  run_gate
  grep -qE "FAIL  two.yml:[0-9]+ setup-buildx without a digest-pinned buildkit image" <<< "${output}"
}

@test "a flow-style with: carrying a pinned image passes" {
  workflow flow.yml \
    "      - { uses: docker/setup-qemu-action@96fe6ef7f33517b61c61be40b68a1882f3264fb8, with: { image: tonistiigi/binfmt:x@${PIN} } }"
  run_gate
  grep -qE "ok    flow.yml:[0-9]+ setup-qemu image pinned" <<< "${output}"
}

@test "an action that sets up QEMU or buildx itself is refused" {
  workflow wrap.yml \
    '      - uses: someone/checkout-qemu-buildx@1ef57f66f3e2960c64983b9ee94e155d466500e1 # v2.0.0'
  run_gate
  grep -qE "FAIL  wrap.yml:[0-9]+ someone/checkout-qemu-buildx@[0-9a-f]+ sets up QEMU or buildx itself" <<< "${output}"
}

@test "quoted trigger keys and a split inline list are still read as triggers" {
  printf 'on:\n  workflow_dispatch:\n  "push":\n    branches: [main]\njobs: {}\n' > "${WF}/release.yml"
  printf 'on: [workflow_dispatch,\n  repository_dispatch]\njobs: {}\n' > "${WF}/withdraw_release.yml"
  run_gate
  grep -qE "FAIL  release.yml: triggers other than workflow_dispatch: push" <<< "${output}"
  grep -qE "FAIL  withdraw_release.yml: triggers other than workflow_dispatch: repository_dispatch" <<< "${output}"
}

@test "quoted permission keys, inline maps and a quoted on: are still read" {
  local q="'"
  printf '"on":\n  pull_request:\njobs:\n  a:\n    permissions:\n      %sid-token%s: write\n  b:\n    permissions: { contents: write }\n  c:\n    permissions: write-all\n' "${q}" "${q}" > "${WF}/pr2.yml"
  run_gate
  grep -qE "FAIL  pr2.yml:6 PR-triggered job asks for id-token: write" <<< "${output}"
  grep -qE "FAIL  pr2.yml:8 PR-triggered job asks for contents: write" <<< "${output}"
  grep -qE "FAIL  pr2.yml:10 PR-triggered job asks for write-all" <<< "${output}"
}

@test "a pinned composite action that calls another action by tag is refused" {
  local loose good
  loose=$(printf 'runs:\n  using: "composite"\n  steps:\n    - uses: actions/checkout@v3.0.2\n' | base64 | tr -d '\n')
  good=$(printf 'runs:\n  using: composite\n  steps:\n    - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0\n' | base64 | tr -d '\n')
  cat > "${TOOLS_DIR}/gh" <<EOF
#!/bin/bash
[ "\$1 \$2" = "auth status" ] && exit 0
case "\$2" in
  repos/acme/wrap/contents/action.yml*) echo "${loose}" ;;
  repos/acme/good/contents/action.yml*) echo "${good}" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "${TOOLS_DIR}/gh"
  workflow comp.yml \
    '      - uses: acme/wrap@1111111111111111111111111111111111111111 # v1.0.0' \
    '      - uses: acme/good@2222222222222222222222222222222222222222 # v1.0.0'
  run_gate
  grep -qE "FAIL  acme/wrap runs actions/checkout@v3.0.2 by tag" <<< "${output}"
  grep -qE "ok    acme/good pins its steps" <<< "${output}"
}
