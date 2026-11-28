#!/bin/bash
# Tells whether a pull request changes the check that judges it.
#
# rules-gate runs master's copy of this script on what a pull request changes,
# read as data. A pull request changes the check when it edits a file that
# decides the rules (the rules, the workflows that run them, the scripts and
# config they rely on) or adds a line that switches a finding off: an inline
# suppression or validate.sh's own opt-out marker. Either way master's rules
# cannot be the judge of it, so the owner is.
#
# Usage: rules_gate.sh <changed paths> <workflow diff>
#   <changed paths>: the paths the pull request changes, NUL-separated, old and
#     new path of a rename both (git diff --no-renames --name-only -z).
#   <workflow diff>: the change to .github/workflows as a unified diff
#     (git diff --no-renames --text -U0), so that a moved line is an added one.
# Prints one line per reason. Exit status: 0 the check is untouched, 1 it is
# changed, 2 usage or an error — never read as untouched.
set -Eeuo pipefail
trap 'exit 2' ERR

if [ $# -ne 2 ] || [ ! -r "$1" ] || [ ! -r "$2" ]; then
    echo "usage: rules_gate.sh <changed paths> <workflow diff>" >&2
    exit 2
fi
paths="$1" diff="$2"

# The files that decide the rules, or what the rules read: lego's pins are
# checked by master's lego_pins.sh, and .gitattributes can change the bytes a
# checkout of the pull request holds.
CHECK_FILES='^(scripts/validate\.sh|\.github/(rules_gate|lego_pins)\.sh|\.github/workflows/(workflow_security|rules_gate)\.ya?ml|\.github/actionlint\.ya?ml|(.*/)?\.gitattributes)$'

# Lines that switch a finding off: zizmor's and shellcheck's inline directives
# (any shellcheck directive, since one comment can carry several) and
# validate.sh's no-release-gate marker.
SUPPRESSION='#[[:space:]]*shellcheck[[:space:]]|zizmor:[[:space:]]*ignore|no-release-gate:'

touched=0

while IFS= read -r -d '' path || [ -n "${path}" ]; do
    if [[ "${path}" == *[[:cntrl:]]* ]]; then
        echo "changes a path with a control character in its name, which cannot be judged"
        touched=1
    elif [[ "${path}" =~ ${CHECK_FILES} ]]; then
        echo "changes ${path}"
        touched=1
    fi
done < "${paths}"

# Added lines only: after a hunk header, up to the next file's header.
added=$(awk -v re="${SUPPRESSION}" '
    /^diff --git / { header = 1; next }
    header && /^\+\+\+ / { file = substr($0, 5); sub(/^b\//, "", file); next }
    /^@@/ { header = 0; next }
    !header && /^\+/ && substr($0, 2) ~ re {
        line = substr($0, 2); sub(/^[[:space:]]+/, "", line)
        printf "adds a suppression: %s: %s\n", file, line
    }
' "${diff}")
if [ -n "${added}" ]; then
    printf '%s\n' "${added}"
    touched=1
fi

exit "${touched}"
