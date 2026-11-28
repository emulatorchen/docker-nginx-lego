# Run Nginx and lego in separate containers, as an opt-in

With `NGINX_LEGO_ROLE`, one image can run as two containers: an issuer that runs
lego and owns the certificate store, and a server that runs Nginx as another uid,
read-only, with the store mounted read-only and no DNS credentials. The default,
`all`, stays the single container everybody runs today.

Since [ADR 0001](./0001-non-root-by-default.md) Nginx's workers share lego's uid,
and in 2026 rewrite-module bugs were chained into code execution in a worker. In
one container that cannot be separated: whatever the worker's uid can read, lego
can, and lego must read the credentials. Two containers under two uids can.

## Considered Options

- **The split as the default.** Rejected: it breaks every single-container
  setup (a second service, a webroot volume, a group, a different uid) for users
  who did not ask for it. Opt-in keeps the upgrade free.
- **A hardened Nginx base image for the server.** Rejected for now: it has no
  shell for the reload watch, and is published for amd64 and arm64 only
  ([#268](https://github.com/emulatorchen/docker-nginx-lego/issues/268)). A
  signal-based reload would allow it later.
- **Reloading the server by signal from the issuer** (a shared PID namespace and
  `CAP_KILL`). Rejected: it gives the issuer power over the server's processes and
  needs a capability; a mark in the store and a watch loop need neither.
- **A new uid for the issuer.** Rejected: the issuer keeps the image user
  `101:101`, so an existing store needs no second `chown`; the server is the new
  uid.

## Consequences

- The server refuses to start, and later to reload, if it runs as root or as the
  issuer's uid, can read the ACME account or a DNS credentials file, or can write
  the store, so a misconfigured server stops with the fix instead of running
  unprotected.
- The issuer refuses to start without `NGINX_LEGO_CERT_GROUP`, and the group now
  also covers `dhparams/`, which the server has to read.
- The server reloads up to `NGINX_LEGO_RELOAD_CHECK` seconds (default 60) after a
  renewal, not at once.
- The image keeps a second copy of its own `conf.d` files, which a server with a
  tmpfs `conf.d` puts back at every start.
- HTTP-01 needs the webroot volume shared between the two; DNS-01 does not.
