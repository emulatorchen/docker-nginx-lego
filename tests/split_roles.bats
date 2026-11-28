#!/usr/bin/env bats
#
# NGINX_LEGO_ROLE splits the image in two on request: an issuer that runs lego
# and owns the certificate store, and a server that runs Nginx with the store
# mounted read-only and no DNS credentials. Unset, the image does both, as
# before. These tests cover the role choice, what each role does after a
# renewal, and the server's checks that it really is cut off from the issuer.

SCRIPTS_DIR="$(cd -- "${BATS_TEST_DIRNAME}/../src/scripts" &> /dev/null && pwd)"

load "${SCRIPTS_DIR}/util.sh"

setup() {
  # Bats before 1.4, which CI runs, has no BATS_TEST_TMPDIR.
  : "${BATS_TEST_TMPDIR:=$(mktemp -d)}"
  unset NGINX_LEGO_ROLE NGINX_LEGO_CERT_GROUP
  STORE="${BATS_TEST_TMPDIR}/store"
  mkdir -p "${STORE}/accounts/acme" "${STORE}/certificates" "${STORE}/live"
  CALLS="${BATS_TEST_TMPDIR}/calls"
  : > "${CALLS}"

  # A fake nginx that records each call; NGINX_T_FAILS=1 makes 'nginx -t' fail.
  mkdir -p "${BATS_TEST_TMPDIR}/bin"
  cat > "${BATS_TEST_TMPDIR}/bin/nginx" <<EOF
#!/bin/sh
echo "nginx \$*" >> "${CALLS}"
if [ "\$1" = "-t" ] && [ "\${NGINX_T_FAILS:-0}" = 1 ]; then exit 1; fi
exit 0
EOF
  chmod +x "${BATS_TEST_TMPDIR}/bin/nginx"
  PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"

  # auto_enable_configs works on /etc/nginx/conf.d; here it only records the call.
  auto_enable_configs() { echo "auto_enable_configs" >> "${CALLS}"; }
}

# ── the role ─────────────────────────────────────────────────────────────────

@test "the role is 'all' when NGINX_LEGO_ROLE is unset or empty" {
  run nginx_lego_role
  [ "${status}" -eq 0 ]
  [ "${output}" = "all" ]
  NGINX_LEGO_ROLE="" run nginx_lego_role
  [ "${output}" = "all" ]
}

@test "issuer and server are accepted as roles" {
  NGINX_LEGO_ROLE=issuer run nginx_lego_role
  [ "${status}" -eq 0 ]
  [ "${output}" = "issuer" ]
  NGINX_LEGO_ROLE=server run nginx_lego_role
  [ "${status}" -eq 0 ]
  [ "${output}" = "server" ]
}

@test "an unknown role stops with the allowed values" {
  NGINX_LEGO_ROLE=bogus run nginx_lego_role
  [ "${status}" -ne 0 ]
  grep -q "\[error\]" <<< "${output}"
  grep -q "all, issuer or server" <<< "${output}"
}

@test "an issuer without NGINX_LEGO_CERT_GROUP refuses to start and names the fix" {
  run check_issuer_ready
  [ "${status}" -ne 0 ]
  grep -q "NGINX_LEGO_CERT_GROUP" <<< "${output}"
  grep -q "group_add" <<< "${output}"
}

@test "an issuer with NGINX_LEGO_CERT_GROUP may start" {
  NGINX_LEGO_CERT_GROUP=10443 run check_issuer_ready
  [ "${status}" -eq 0 ]
}

# ── after a renewal ──────────────────────────────────────────────────────────

@test "after a renewal the single container checks the config and reloads Nginx" {
  run after_renewal "${STORE}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${CALLS}")" = "$(printf 'auto_enable_configs\nnginx -t\nnginx -s reload')" ]
}

@test "after a renewal a config that fails nginx -t is not reloaded, and that is logged" {
  NGINX_T_FAILS=1 run after_renewal "${STORE}"
  [ "${status}" -eq 0 ]
  ! grep -q "reload" "${CALLS}"
  grep -q "\[error\]" <<< "${output}"
}

@test "after a renewal the issuer only marks the store, it never calls Nginx" {
  NGINX_LEGO_ROLE=issuer run after_renewal "${STORE}"
  [ "${status}" -eq 0 ]
  [ -f "${STORE}/.nginx-lego-renewed" ]
  first="$(cat "${STORE}/.nginx-lego-renewed")"
  NGINX_LEGO_ROLE=issuer run after_renewal "${STORE}"
  [ "$(cat "${STORE}/.nginx-lego-renewed")" != "${first}" ]
  [ ! -s "${CALLS}" ]
}

# ── the server is cut off from the issuer ────────────────────────────────────
# The test user owns the store it makes, which is what the issuer's uid looks
# like to the check; cases about the other rules stand in another owner.

another_owner() { store_owner() { echo 4242; }; }

@test "a server running as root refuses, and says to run as another uid" {
  [ "$(id -u)" -eq 0 ] || skip "only root can be root"
  run check_server_isolation "${STORE}"
  [ "${status}" -ne 0 ]
  grep -q "runs as root" <<< "${output}"
  grep -q "another uid" <<< "${output}"
}

@test "a server running as the store's owner, the issuer's uid, refuses even with nothing readable yet" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused before this rule"
  rmdir "${STORE}/accounts/acme" "${STORE}/accounts"
  chmod -w "${STORE}"
  run check_server_isolation "${STORE}"
  chmod u+w "${STORE}"
  [ "${status}" -ne 0 ]
  grep -q "owns the certificate store" <<< "${output}"
  grep -q "another uid" <<< "${output}"
}

@test "a server that can read the ACME account refuses, and says to run as another uid" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused before this rule"
  another_owner
  chmod -w "${STORE}"
  run check_server_isolation "${STORE}"
  chmod u+w "${STORE}"
  [ "${status}" -ne 0 ]
  grep -q "accounts" <<< "${output}"
  grep -q "another uid" <<< "${output}"
}

@test "a server that can read a DNS credentials file refuses" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused before this rule"
  another_owner
  chmod 000 "${STORE}/accounts"
  echo "CLOUDFLARE_DNS_API_TOKEN=secret" > "${STORE}/cloudflare.ini"
  chmod 644 "${STORE}/cloudflare.ini"
  chmod -w "${STORE}"
  run check_server_isolation "${STORE}"
  chmod u+w "${STORE}"
  chmod 700 "${STORE}/accounts"
  [ "${status}" -ne 0 ]
  grep -q "cloudflare.ini" <<< "${output}"
}

@test "a server that can write the store refuses, and says to mount it read-only" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused before this rule"
  another_owner
  chmod 000 "${STORE}/accounts"
  run check_server_isolation "${STORE}"
  chmod 700 "${STORE}/accounts"
  [ "${status}" -ne 0 ]
  grep -q ":ro" <<< "${output}"
}

@test "a server cut off from the issuer passes" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused; the smoke test covers this as uid 102"
  another_owner
  chmod 000 "${STORE}/accounts"
  echo "CLOUDFLARE_DNS_API_TOKEN=secret" > "${STORE}/cloudflare.ini"
  chmod 000 "${STORE}/cloudflare.ini"
  chmod -w "${STORE}"
  run check_server_isolation "${STORE}"
  chmod u+w "${STORE}"
  chmod 700 "${STORE}/accounts"
  [ "${status}" -eq 0 ]
}

@test "a server passes before the issuer has made any account" {
  [ "$(id -u)" -ne 0 ] || skip "root is refused; the smoke test covers this as uid 102"
  another_owner
  rmdir "${STORE}/accounts/acme" "${STORE}/accounts"
  chmod -w "${STORE}"
  run check_server_isolation "${STORE}"
  chmod u+w "${STORE}"
  [ "${status}" -eq 0 ]
}

# ── the server picks up a renewal ────────────────────────────────────────────

@test "the server reloads once when the issuer marked a renewal, and not again for the same one" {
  local seen="${BATS_TEST_TMPDIR}/seen"
  NGINX_LEGO_ROLE=issuer after_renewal "${STORE}"
  : > "${CALLS}"

  run server_watch_once "${STORE}" "${seen}"
  [ "${status}" -eq 0 ]
  [ "$(cat "${CALLS}")" = "$(printf 'auto_enable_configs\nnginx -t\nnginx -s reload')" ]

  : > "${CALLS}"
  run server_watch_once "${STORE}" "${seen}"
  [ ! -s "${CALLS}" ]
}

@test "the server does nothing while the issuer has not renewed anything" {
  run server_watch_once "${STORE}" "${BATS_TEST_TMPDIR}/seen"
  [ "${status}" -eq 0 ]
  [ ! -s "${CALLS}" ]
}

@test "the server does not reload a config that fails nginx -t" {
  NGINX_LEGO_ROLE=issuer after_renewal "${STORE}"
  : > "${CALLS}"
  NGINX_T_FAILS=1 run server_watch_once "${STORE}" "${BATS_TEST_TMPDIR}/seen"
  ! grep -q "reload" "${CALLS}"
  grep -q "\[error\]" <<< "${output}"
}
