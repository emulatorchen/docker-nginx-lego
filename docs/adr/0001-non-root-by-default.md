# Run every image as non-root, with no root variant

Every image variant, on every architecture, runs as the unprivileged `nginx` user
`101:101` from `lego5.6.0-nginx1.31.8` on. Nothing in the image needs root once
the folders it writes belong to that user, and containers that consume its
certificates (a non-root TLS terminator, for one) should not need root either;
`NGINX_LEGO_CERT_GROUP` gives them read access through a group instead.

## Considered Options

- **A separate root tag next to the non-root one.** Rejected: it doubles every
  release for a mode the project does not need, and leaves the root image as the
  default most people pull.
- **File capabilities (`cap_net_bind_service`) on the nginx binary.** Rejected:
  a binary with file capabilities cannot be executed when the container drops all
  capabilities, a common Kubernetes setting. Docker already allows unprivileged
  ports, and other runtimes take a sysctl.
- **Documenting `--user 0` as a fallback.** Rejected: the fix for an existing
  volume is a one-time `chown`, which the container prints itself.
- **Moving the pid file to `/tmp`.** Rejected: `/run` is given to the `nginx`
  user instead, so a mounted `nginx.conf` with `pid /run/nginx.pid` keeps working.

## Consequences

- Existing volumes and host directories written by a root-run image need a
  one-time `chown -R 101:101`; the container checks this at startup and stops
  with that command.
- The folders the container writes are also writable by group `0`, so platforms
  that force their own uid in group `0` (OpenShift, Kubernetes `runAsUser`) work.
- The Ubuntu image creates the `nginx` user as `101:101` itself, so every variant
  shares one uid, and every build checks it.
- Nginx's workers now share the uid that lego runs as. Under root the master and
  lego kept the DNS credentials and the ACME account key out of the workers' reach;
  now a compromised worker could read them. In exchange nothing in the container
  runs as root any more, lego included. The docs ask for least-privilege DNS tokens.
