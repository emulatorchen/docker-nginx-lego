# Available Image Tags

Tags encode the exact component versions inside the image. Use a specific tag
in production — `latest` tracks `master` and is not considered stable.

## Tag Format

```
lego<LEGO_VERSION>-nginx<NGINX_VERSION>
lego<LEGO_VERSION>-nginx<NGINX_VERSION>-alpine
```

For script-only fixes (no component version change), a revision suffix is
appended:

```
lego<LEGO_VERSION>-nginx<NGINX_VERSION>-r<N>
lego<LEGO_VERSION>-nginx<NGINX_VERSION>-r<N>-alpine
```

Shorter tags (`lego<X.Y.Z>`, `lego<X.Y.Z>-alpine`) always point to the latest
nginx for that lego version, and move as updates are released.

## Current Tags

| Lego    | Nginx  | Tag                              |
| :------ | :----- | :------------------------------- |
| 4.33.0  | 1.29.5 | `lego4.33.0-nginx1.29.5`         |
|         |        | `lego4.33.0-nginx1.29.5-alpine`  |

## Architecture Support

| Architecture  | Debian | Alpine |
| :------------ | :----- | :----- |
| linux/amd64   | ✅     | ✅     |
| linux/386     | ✅     | ❌     |
| linux/arm64   | ✅     | ✅     |
| linux/arm/v7  | ✅     | ❌     |

## Update Cadence

- **Lego bumps** — automated weekly via `check-lego-update` workflow; opens a
  PR updating `ARG LEGO_VERSION` in both Dockerfiles.
- **Nginx bumps** — automated weekly via `check-nginx-update` workflow; opens
  a PR updating the `FROM nginx:` base image line.
- **Script-only fixes** — manual; tagged with a `-r<N>` revision suffix.
- **Base image security patches** — nginx Docker Hub rebuilds the same tag
  periodically; re-pulling the image picks these up without a version bump.

## Upstream

This image is a fork of [`JonasAlfredsson/docker-nginx-certbot`][upstream] with
certbot replaced by [lego][lego]. For the upstream tag history see the
[upstream repo][upstream].

[upstream]: https://github.com/JonasAlfredsson/docker-nginx-certbot
[lego]: https://github.com/go-acme/lego
