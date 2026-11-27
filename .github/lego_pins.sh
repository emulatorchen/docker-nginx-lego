#!/bin/bash
# Pins the lego binary the images install to tarballs lego's own release
# workflow attested.
#
# Every Dockerfile checks the lego tarball it downloads against
# ARG LEGO_SHA256_<ARCH>. A checksum file from the same release would prove
# nothing: whoever could replace a tarball could replace that file too. So the
# pins come from here, and here a tarball is only accepted once gh has verified
# that go-acme/lego's release workflow, building that exact tag, attested it.
#
#   lego_pins.sh --update <X.Y.Z> [Dockerfile...]  verify that release and write
#                                                  ARG LEGO_VERSION and the pins
#   lego_pins.sh --check [Dockerfile...]           verify that the pinned tarballs
#                                                  are the attested ones
#
# Default Dockerfiles: src/Dockerfile*. Nothing is written unless every
# architecture verifies. Needs gh (GH_TOKEN) and curl.
# Exit status: 0 ok, 1 not verified or not matching, 2 usage.
set -euo pipefail

ARCHES="amd64 386 arm64 armv7"
SIGNER="go-acme/lego/.github/workflows/release.yml"

usage() {
    echo "usage: lego_pins.sh --update <X.Y.Z> [Dockerfile...] | --check [Dockerfile...]" >&2
    exit 2
}

# arg <file> <name>: the value of 'ARG <name>=' in <file>, or nothing.
arg() {
    sed -n "s/^ARG $2=//p" "$1" | head -n 1
}

upper() {
    printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

# verified_sum <version> <arch> <dir>: the sha256 of that tarball, printed only
# after gh has verified lego's attestation for it.
verified_sum() {
    local version="$1" arch="$2" dir="$3"
    local tarball="lego_v${version}_linux_${arch}.tar.gz"
    if ! curl -fsSL -o "${dir}/${tarball}" \
            "https://github.com/go-acme/lego/releases/download/v${version}/${tarball}"; then
        echo "lego ${version} ${arch}: cannot download ${tarball}" >&2
        return 1
    fi
    if ! gh attestation verify "${dir}/${tarball}" --repo go-acme/lego \
            --signer-workflow "${SIGNER}" --source-ref "refs/tags/v${version}" > /dev/null; then
        echo "lego ${version} ${arch}: ${tarball} is not attested by ${SIGNER} at v${version}" >&2
        return 1
    fi
    sha256sum "${dir}/${tarball}" | cut -d' ' -f1
}

mode="${1:-}"
version=""
case "${mode}" in
    --update)
        version="${2:-}"
        [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
        shift 2
        ;;
    --check) shift ;;
    *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
if [ $# -eq 0 ]; then
    set -- "${root}/src/Dockerfile" "${root}/src/Dockerfile-alpine" "${root}/src/Dockerfile-ubuntu"
fi

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

if [ "${mode}" = --check ]; then
    version=$(arg "$1" LEGO_VERSION)
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "$1: no ARG LEGO_VERSION=X.Y.Z" >&2; exit 1; }
    fail=0
    for file in "$@"; do
        if [ "$(arg "${file}" LEGO_VERSION)" != "${version}" ]; then
            echo "${file}: LEGO_VERSION disagrees with $1" >&2; fail=1
        fi
        for arch in ${ARCHES}; do
            if [ "$(arg "${file}" "LEGO_SHA256_$(upper "${arch}")")" != "$(arg "$1" "LEGO_SHA256_$(upper "${arch}")")" ]; then
                echo "${file}: LEGO_SHA256_$(upper "${arch}") disagrees with $1" >&2; fail=1
            fi
        done
    done
    [ "${fail}" -eq 0 ] || exit 1
    for arch in ${ARCHES}; do
        sum=$(verified_sum "${version}" "${arch}" "${work}") || exit 1
        pinned=$(arg "$1" "LEGO_SHA256_$(upper "${arch}")")
        if [ "${sum}" != "${pinned}" ]; then
            echo "lego ${version} ${arch}: pinned ${pinned:-nothing}, the attested tarball is ${sum}" >&2
            exit 1
        fi
        echo "lego ${version} ${arch}: ${sum} attested by ${SIGNER}"
    done
    exit 0
fi

# --update: every file must carry all the lines to set, or a pin would silently
# stay behind; then verify every architecture, then write all files at once.
missing=0
for file in "$@"; do
    for name in LEGO_VERSION $(for a in ${ARCHES}; do printf 'LEGO_SHA256_%s ' "$(upper "${a}")"; done); do
        if ! grep -q "^ARG ${name}=" "${file}"; then
            echo "${file}: has no ARG ${name}= line to set" >&2
            missing=1
        fi
    done
done
[ "${missing}" -eq 0 ] || exit 1

# The sums are kept in files rather than an associative array, so this also
# runs under the bash 3.2 macOS ships.
for arch in ${ARCHES}; do
    verified_sum "${version}" "${arch}" "${work}" > "${work}/sum.${arch}" || exit 1
    echo "lego ${version} ${arch}: $(cat "${work}/sum.${arch}") attested by ${SIGNER}"
done
for file in "$@"; do
    edit="s/^ARG LEGO_VERSION=.*/ARG LEGO_VERSION=${version}/"
    for arch in ${ARCHES}; do
        edit="${edit};s/^ARG LEGO_SHA256_$(upper "${arch}")=.*/ARG LEGO_SHA256_$(upper "${arch}")=$(cat "${work}/sum.${arch}")/"
    done
    # -i.bak works with both GNU and BSD sed.
    sed -i.bak "${edit}" "${file}"
    rm -f "${file}.bak"
done
