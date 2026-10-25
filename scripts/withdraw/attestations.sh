#!/usr/bin/env bash
# scripts/withdraw/attestations.sh — remove the attestation records of TAG's images.
#
# Last: a record for an image that is already gone is harmless for the moment it
# takes to get here, while removing it first would leave a live image without
# its proof. A variant whose version tag stays (KEPT) keeps its records too. The
# Sigstore transparency-log entry behind a record is append-only and stays.
#
# Env: DIGESTS, KEPT (may be empty), OWNER, GH_TOKEN

HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=scripts/withdraw/lib.sh
. "$HERE/lib.sh"

need OWNER GH_TOKEN
for v in $VARIANTS; do
  d=$(digest_for "$v")
  [ -n "$d" ] || continue
  is_digest "$d" || die "'${d}' is not a sha256 digest"
  case " ${KEPT:-} " in
    *" ${v} "*) echo "${v}: its version tag stays, so its attestation records stay"; continue ;;
  esac
  if out=$(gh api -X DELETE "users/${OWNER}/attestations/digest/${d}" 2>&1); then
    echo "${v}: attestation records for ${d} deleted"
  else
    case "$out" in
      *404*) echo "${v}: no attestation records for ${d}" ;;
      *) die "could not delete the attestation records for ${d}: ${out}" ;;
    esac
  fi
done
