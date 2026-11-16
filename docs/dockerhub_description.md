# docker-nginx-lego

Nginx with automatic SSL/TLS certificate management via [Let's Encrypt](https://letsencrypt.org/)
and [lego](https://github.com/go-acme/lego). No Python. No certbot. Just a static Go binary.

Fork of [JonasAlfredsson/docker-nginx-certbot](https://github.com/JonasAlfredsson/docker-nginx-certbot)
with certbot replaced by lego — endorsed by the upstream author.

> **⚠️ Breaking change from `lego5.6.0-nginx1.31.8`: the image no longer runs as root.**
> Every image now runs as the unprivileged user `101:101`. `latest`, `latest-alpine`
> and `latest-ubuntu` move to it on release; `lego5.4.1-nginx1.31.8` and older still
> run as root. **An existing setup needs a one-time migration**, most often:
> `docker run --rm --user 0 -v <volume-or-dir>:/etc/letsencrypt emulator/docker-nginx-lego chown -R 101:101 /etc/letsencrypt`.
> Read [Upgrading to the Non-Root Image](https://github.com/emulatorchen/docker-nginx-lego#upgrading-to-the-non-root-image)
> before you pull.

## Quick start

```bash
docker run -d -p 80:80 -p 443:443 \
  --cap-drop ALL --security-opt no-new-privileges \
  -e CERTBOT_EMAIL=your@email.com \
  -v nginx_secrets:/etc/letsencrypt \
  -v $(pwd)/user_conf.d:/etc/nginx/user_conf.d:ro \
  emulator/docker-nginx-lego:lego5.6.0-nginx1.31.8
```

Place your nginx server configs in `user_conf.d/`. The container handles cert
issuance and renewal automatically.

Nginx's workers run as the same user as lego, so code running in a worker could
read your DNS credentials. Use least-privilege DNS tokens and keep the two flags
above; see [What it means for security](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/good_to_know.md#what-it-means-for-security).

## Tags

Tags encode the exact component versions:

```
lego<X.Y.Z>-nginx<X.Y.Z>          # Debian
lego<X.Y.Z>-nginx<X.Y.Z>-alpine   # Alpine
lego<X.Y.Z>-nginx<X.Y.Z>-ubuntu   # Ubuntu 24.04
```

Use a specific tag in production. See the
[full tag list](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/dockerhub_tags.md).

## Certificate naming

The cert name in your nginx config drives how the certificate is obtained:

```nginx
# HTTP-01 webroot (default)
ssl_certificate_key /etc/letsencrypt/live/example.com/privkey.pem;

# DNS-01 via Cloudflare
ssl_certificate_key /etc/letsencrypt/live/example.com.dns-cloudflare/privkey.pem;

# DNS-01 via Route53 (env vars, no .ini file needed)
ssl_certificate_key /etc/letsencrypt/live/example.com.dns-route53/privkey.pem;
```

150+ DNS providers supported. See the
[provider list](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/lego_providers.md).

## Key environment variables

| Variable | Default | Purpose |
|---|---|---|
| `CERTBOT_EMAIL` | required | Let's Encrypt account email |
| `STAGING` | `0` | Use LE staging servers (set to `1` for testing) |
| `LEGO_DEFAULT_PROVIDER` | — | Default DNS provider for all certs |
| `CERTBOT_DNS_CREDENTIALS_DIR` | `/etc/letsencrypt` | Directory for `.ini` credential files |
| `RENEWAL_INTERVAL` | `8d` | Time between renewal checks |
| `USE_ECDSA` | `1` | ECDSA certs (set to `0` for RSA only) |
| `NGINX_LEGO_CERT_GROUP` | — | Group (name or gid) given read access to the certificates, for another container ([how](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/advanced_usage.md#share-certificates-with-another-container)) |

## Volumes

| Path | Purpose |
|---|---|
| `/etc/letsencrypt` | Certificates, lego accounts, DH params (persist this; writable by uid 101) |
| `/etc/nginx/user_conf.d` | Your nginx server configs (mount read-only) |

## Architectures

| Architecture | Debian | Alpine | Ubuntu |
|---|---|---|---|
| linux/amd64 | ✓ | ✓ | ✓ |
| linux/386 | ✓ | — | — |
| linux/arm64 | ✓ | ✓ | ✓ |
| linux/arm/v7 | ✓ | — | — |

## Links

- [GitHub repository & docs](https://github.com/emulatorchen/docker-nginx-lego)
- [Advanced usage](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/advanced_usage.md)
- [Good to know](https://github.com/emulatorchen/docker-nginx-lego/blob/master/docs/good_to_know.md)
- [Upstream project](https://github.com/JonasAlfredsson/docker-nginx-certbot)
