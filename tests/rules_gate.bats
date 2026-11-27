#!/usr/bin/env bats
#
# .github/rules_gate.sh decides whether a pull request changes the check that
# judges it: a file that decides the rules, or an added line that switches a
# finding off. Then master's rules cannot judge the pull request and the owner
# has to. Its input is what git diff prints for the pull request.

SCRIPT="${BATS_TEST_DIRNAME}/../.github/rules_gate.sh"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  PATHS="${BATS_TEST_TMPDIR}/changed.z"
  DIFF="${BATS_TEST_TMPDIR}/workflows.diff"
  printf 'src/Dockerfile\0README.md\0' > "${PATHS}"
  : > "${DIFF}"
}

gate() {
  run bash "${SCRIPT}" "${PATHS}" "${DIFF}"
}

# hunk <file> <diff lines...>: a -U0 diff of <file> holding the given lines.
hunk() {
  local f="$1"; shift
  printf 'diff --git a/%s b/%s\nindex 1111111..2222222 100644\n--- a/%s\n+++ b/%s\n@@ -10,0 +11 @@ jobs:\n' \
    "$f" "$f" "$f" "$f"
  printf '%s\n' "$@"
}

@test "a pull request that leaves the check alone passes through" {
  gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "editing a file that decides the rules changes the check" {
  for f in scripts/validate.sh .github/rules_gate.sh .github/lego_pins.sh \
           .github/workflows/workflow_security.yml .github/workflows/rules_gate.yml \
           .github/workflows/rules_gate.yaml .github/actionlint.yaml .github/actionlint.yml \
           .gitattributes src/.gitattributes; do
    printf 'README.md\0%s\0' "${f}" > "${PATHS}"
    gate
    [ "$status" -eq 1 ] || { echo "not caught: ${f}"; false; }
    [[ "$output" == *"changes ${f}"* ]]
  done
}

@test "renaming a rules file away counts: the old path is listed" {
  printf 'scripts/lint.sh\0scripts/validate.sh\0' > "${PATHS}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"changes scripts/validate.sh"* ]]
}

@test "files that only look like rules files do not count" {
  printf 'docs/scripts/validate.sh\0scripts/validate.sh.bak\0.github/workflows/workflow_security_extra.yml\0.github/workflows/unit_tests.yml\0.github/lego_pins.sh.orig\0' > "${PATHS}"
  gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a path with a newline or another control character cannot be judged" {
  printf 'README.md\0.github/workflows/a\nb.yml\0' > "${PATHS}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"control character"* ]]
  printf 'docs/a\tb.md\0' > "${PATHS}"
  gate
  [ "$status" -eq 1 ]
}

@test "the last path counts without a trailing NUL" {
  printf 'README.md\0scripts/validate.sh' > "${PATHS}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"changes scripts/validate.sh"* ]]
}

@test "an added zizmor suppression changes the check" {
  hunk .github/workflows/ci.yml '+      - run: echo "${{ github.ref }}" # zizmor: ignore[template-injection]' > "${DIFF}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *'adds a suppression: .github/workflows/ci.yml: - run: echo "${{ github.ref }}" # zizmor: ignore[template-injection]'* ]]
}

@test "any added shellcheck directive changes the check, combined ones too" {
  for d in '# shellcheck disable=SC2086' '# shellcheck source=/dev/null disable=SC2086' '#shellcheck  disable=all'; do
    hunk .github/workflows/ci.yml "+          ${d}" > "${DIFF}"
    gate
    [ "$status" -eq 1 ] || { echo "not caught: ${d}"; false; }
    [[ "$output" == *"adds a suppression: .github/workflows/ci.yml: ${d}"* ]]
  done
}

@test "validate.sh's own opt-out marker changes the check" {
  hunk .github/workflows/new.yml '+  # no-release-gate: publishes nothing' > "${DIFF}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"adds a suppression: .github/workflows/new.yml: # no-release-gate: publishes nothing"* ]]
}

@test "moving a suppression counts as adding it" {
  hunk .github/workflows/scan.yml '-          # shellcheck disable=SC2086' '+          # shellcheck disable=SC2086' > "${DIFF}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"adds a suppression"* ]]
}

@test "removing a suppression, or changing other lines, does not change the check" {
  hunk .github/workflows/scan.yml '-          # shellcheck disable=SC2086' '+          echo "no directive here"' > "${DIFF}"
  gate
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "an added line that starts with +++ is still read as an added line" {
  hunk .github/workflows/ci.yml '+++ x # zizmor: ignore[unpinned-uses]' > "${DIFF}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"adds a suppression: .github/workflows/ci.yml"* ]]
}

@test "suppressions in a second file of the diff are named with that file" {
  { hunk .github/workflows/a.yml '+      - run: echo a'; hunk .github/workflows/b.yml '+  # zizmor: ignore[excessive-permissions]'; } > "${DIFF}"
  gate
  [ "$status" -eq 1 ]
  [[ "$output" == *"adds a suppression: .github/workflows/b.yml"* ]]
  [[ "$output" != *"a.yml"* ]]
}

@test "missing or unreadable input is a usage error, not a pass" {
  run bash "${SCRIPT}" "${PATHS}"
  [ "$status" -eq 2 ]
  run bash "${SCRIPT}" "${PATHS}" "${BATS_TEST_TMPDIR}/no-diff"
  [ "$status" -eq 2 ]
}

@test "an internal error exits 2, never 1 (changed) or 0" {
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  printf '#!/bin/sh\nexit 3\n' > "${BATS_TEST_TMPDIR}/bin/awk"
  chmod +x "${BATS_TEST_TMPDIR}/bin/awk"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}" run bash "${SCRIPT}" "${PATHS}" "${DIFF}"
  [ "$status" -eq 2 ]
}
