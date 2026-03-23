# docker-nginx-lego

Automatically create and renew website SSL certificates using the
[Let's Encrypt][1] free certificate authority and its client [*lego*][2].
Built on top of the [official Nginx Docker images][9] (both Debian and Alpine),
and uses OpenSSL/LibreSSL to automatically create the Diffie-Hellman parameters
used during the initial handshake of some ciphers.

This is a fork of [`JonasAlfredsson/docker-nginx-certbot`][upstream], with
certbot replaced entirely by [lego][2] — a self-contained Go binary that
supports HTTP-01 webroot and DNS-01 challenges across 150+ DNS providers.
The upstream author [suggested this fork][pr373] and offered to link to it.

> :information_source: The very first time this container is started it might
  take a long time before it is ready to respond to requests. Read more
  about this in the
  [Diffie-Hellman parameters](./docs/good_to_know.md#diffie-hellman-parameters)
  section.

> :information_source: Please use a [specific tag](./docs/dockerhub_tags.md)
  when doing a Docker pull, since `:latest` might not always be 100% stable.

### Noteworthy Features
- Handles multiple server names when [requesting certificates](./docs/good_to_know.md#how-the-script-add-domain-names-to-certificate-requests) (i.e. both `example.com` and `www.example.com`).
- Handles wildcard domain requests via [DNS-01 challenges](./docs/lego_providers.md).
- Can request both [RSA and ECDSA](./docs/good_to_know.md#ecdsa-and-rsa-certificates) certificates ([at the same time](./docs/advanced_usage.md#multi-certificate-setup)).
- Will create [Diffie-Hellman parameters](./docs/good_to_know.md#diffie-hellman-parameters) if they are defined.
- Uses the [parent container][9]'s [`/docker-entrypoint.d/`][7] folder.
- Will report correct [exit code][6] when stopped/killed/failed.
- You can do a live reload of configs by [sending in a `SIGHUP`](./docs/advanced_usage.md#manualforce-renewal) signal (no container restart needed).
- Possibility to use this image **offline** with the help of a [local CA](./docs/advanced_usage.md#local-ca).
- Both [Debian and Alpine](./docs/dockerhub_tags.md) images built for [multiple architectures][14].
- **No Python dependency** — lego is a static Go binary; images are significantly smaller.
- **150+ DNS providers** supported natively by lego (see [lego provider list][lego-providers]).



# Acknowledgments and Thanks

This container requests SSL certificates from [Let's Encrypt][1], which they
provide for the absolutely bargain price of free! If you like what they do,
please [donate][3].

This repository is a fork of [`JonasAlfredsson/docker-nginx-certbot`][upstream],
which itself was originally forked from [`@staticfloat`][5] and
[`@henridwyer`][4]. The certbot-to-lego migration was [encouraged by the
upstream author][pr373].



# Usage

## Before You Start
1. This guide expects you to already own a domain which points at the correct
   IP address, and that you have both port `80` and `443` correctly forwarded
   if you are behind NAT. Otherwise check [DuckDNS][12] as a Dynamic DNS
   provider.

2. I suggest you read at least the first two sections in the
   [Good to Know](./docs/good_to_know.md) documentation, since this will give
   you some important tips on how to create a basic server config, and how to
   use the Let's Encrypt staging servers in order to not get rate limited.

3. You will need to have [Docker][11] installed.


## Available Environment Variables

### Required
- `CERTBOT_EMAIL`: Your e-mail address. Used by Let's Encrypt to contact you in case of security issues.

### Optional
- `DHPARAM_SIZE`: The size of the [Diffie-Hellman parameters](./docs/good_to_know.md#diffie-hellman-parameters) (default: `2048`)
- `ELLIPTIC_CURVE`: The size/[curve][15] of the ECDSA keys (default: `secp256r1`)
- `RENEWAL_INTERVAL`: Time interval between lego's [renewal checks](./docs/good_to_know.md#renewal-check-interval) (default: `8d`)
- `RSA_KEY_SIZE`: The size of the RSA encryption keys (default: `2048`)
- `STAGING`: Set to `1` to use Let's Encrypt's [staging servers](./docs/good_to_know.md#initial-testing) (default: `0`)
- `USE_ECDSA`: Set to `0` to use RSA instead of ECDSA (default: `1`)

### Advanced
- `LEGO_DEFAULT_PROVIDER`: Default DNS provider for all certs without an explicit `.dns-<provider>` suffix (e.g. `cloudflare`). See [lego providers](./docs/lego_providers.md).
- `CERTBOT_AUTHENTICATOR`: Backward-compatible alias for `LEGO_DEFAULT_PROVIDER`. Set to `webroot` or `dns-<provider>`.
- `CERTBOT_DNS_CREDENTIALS_DIR`: Directory where `.ini` credentials files for [DNS providers](./docs/lego_providers.md) are located (default: `/etc/letsencrypt`).
- `DEBUG`: Set to `1` to enable debug messages and use the [`nginx-debug`][10] binary (default: `0`)
- `USE_LOCAL_CA`: Set to `1` to enable the use of a [local certificate authority](./docs/advanced_usage.md#local-ca) (default: `0`)


## Certificate Naming Convention

lego determines the challenge type from the `ssl_certificate_key` path in your
nginx config. The suffix of the certificate name drives behavior:

| Cert name | Challenge | Credentials |
|---|---|---|
| `example.com` | HTTP-01 webroot | none needed |
| `example.com.webroot` | HTTP-01 webroot | none needed |
| `example.com.dns-cloudflare` | DNS-01 via cloudflare | `cloudflare.ini` |
| `example.com.dns-route53` | DNS-01 via route53 | env vars (AWS_*) |
| `example.com.dns-<any>` | DNS-01 via lego provider | `<any>.ini` |
| `example.com.dns-cloudflare_1` | DNS-01 via cloudflare | `cloudflare_1.ini` |
| `example.com.rsa` | forces RSA key type | — |
| `example.com.ecdsa` | forces ECDSA key type | — |

The suffixes can be combined: `example.com.dns-cloudflare.rsa` requests an
RSA cert via Cloudflare DNS.

**nginx config example:**
```nginx
ssl_certificate_key /etc/letsencrypt/live/example.com.dns-cloudflare/privkey.pem;
```


## Credentials File Format

lego uses environment variables for provider credentials. Store them in a
`.ini` file as `KEY=VALUE` pairs:

```ini
# /etc/letsencrypt/cloudflare.ini
CLOUDFLARE_DNS_API_TOKEN=your-token-here
```

The file name must match the provider suffix in the cert name. For a cert
named `example.com.dns-cloudflare`, the file is `cloudflare.ini`. For
`example.com.dns-cloudflare_1`, it is `cloudflare_1.ini`.

See [lego providers documentation](./docs/lego_providers.md) for the full list
of providers and their required environment variables.

**Legacy `dns-multi` format** (backward compatible):
```ini
# /etc/letsencrypt/multi.ini
dns_multi_provider = cloudflare
CLOUDFLARE_DNS_API_TOKEN = your-token-here
```


## Volumes
- `/etc/letsencrypt`: Stores the obtained certificates and the Diffie-Hellman parameters


## Run with `docker run`
Create your own [`user_conf.d/`](./docs/good_to_know.md#the-user_confd-folder)
folder and place all of your custom server config files in there. Then start
the container:

```bash
docker run -it -p 80:80 -p 443:443 \
           --env CERTBOT_EMAIL=your@email.org \
           -v $(pwd)/nginx_secrets:/etc/letsencrypt \
           -v $(pwd)/user_conf.d:/etc/nginx/user_conf.d:ro \
           --name nginx-lego emulator/docker-nginx-lego:latest
```

> You should be able to detach from the container by holding `Ctrl` and pressing
  `p` + `q` after each other.

As was mentioned in the introduction, the very first time this container is
started it might take a long time before it is ready to
[respond to requests](./docs/good_to_know.md#diffie-hellman-parameters). If you
change any config files after the container is ready, send a `SIGHUP` to
reload:

```bash
docker kill --signal=HUP <container_name>
```


## Run with `docker-compose`
An example of a [`docker-compose.yaml`](./examples/docker-compose.yml) file can
be found in the [`examples/`](./examples) folder. The default parameters that
are found inside the [`nginx-lego.env`](./examples/nginx-lego.env) file
will be overwritten by any environment variables you set inside the `.yaml`
file.

```bash
docker-compose up
```


## Build It Yourself
```Dockerfile
FROM emulator/docker-nginx-lego:latest
COPY conf.d/* /etc/nginx/conf.d/
```


## Migrating from docker-nginx-certbot

If you previously used `JonasAlfredsson/docker-nginx-certbot` or this repo
before the lego migration:

1. **Credential file format**: certbot used INI-style keys
   (`dns_cloudflare_api_token = xxx`). lego uses env vars (`CLOUDFLARE_DNS_API_TOKEN=xxx`).
   Update your `.ini` files to the new `KEY=VALUE` format. See
   [lego providers](./docs/lego_providers.md) for the env var names for your provider.

2. **`CERTBOT_AUTHENTICATOR` env var**: still works as a backward-compatible
   alias. Prefer `LEGO_DEFAULT_PROVIDER` going forward.

3. **`CERTBOT_DNS_PROPAGATION_SECONDS`**: removed. lego uses provider-specific
   env vars instead (e.g. `CLOUDFLARE_PROPAGATION_TIMEOUT`). Set these in your
   `.ini` file if needed.

4. **ACME account**: lego registers a new ACME account under
   `/etc/letsencrypt/accounts/`. Your existing certificates are unaffected.

5. **`dns-multi` certs**: fully backward compatible — existing `multi.ini` files
   work without changes.



# Tests
We make use of [BATS][16] to test parts of this codebase. The easiest way to
run all the tests is to execute the following command in the root of this
repository:

```bash
docker run -it --rm -v "$(pwd):/workdir" ffurrer/bats:latest ./tests
```



# More Resources
Here is a collection of links to other resources that provide useful
information.

- [Good to Know](./docs/good_to_know.md)
  - A lot of good to know stuff about this image and the features it provides.
- [Changelog](./docs/changelog.md)
  - List of all the tagged versions of this repository, as well as bullet points to what has changed between the releases.
- [DockerHub Tags](./docs/dockerhub_tags.md)
  - All the tags available from Docker Hub.
- [Advanced Usage](./docs/advanced_usage.md)
  - Information about the more advanced features this image provides.
- [Lego Providers](./docs/lego_providers.md)
  - DNS provider list, credential file format, and provider-specific notes.
- [Nginx Tips](./docs/nginx_tips.md)
  - Some interesting tips on how Nginx can be configured.



[1]: https://letsencrypt.org/
[2]: https://github.com/go-acme/lego
[3]: https://letsencrypt.org/donate/
[4]: https://github.com/henridwyer/docker-letsencrypt-cron
[5]: https://github.com/staticfloat/docker-nginx-certbot
[6]: https://github.com/JonasAlfredsson/docker-nginx-certbot/commit/43dde6ec24f399fe49729b28ba4892665e3d7078
[7]: https://github.com/nginxinc/docker-nginx/tree/master/entrypoint
[8]: https://hub.docker.com/r/emulator/docker-nginx-lego
[9]: https://github.com/nginxinc/docker-nginx
[10]: https://github.com/docker-library/docs/tree/master/nginx#running-nginx-in-debug-mode
[11]: https://docs.docker.com/engine/install/
[12]: https://www.duckdns.org/
[13]: https://portforward.com/router.htm
[14]: https://github.com/JonasAlfredsson/docker-nginx-certbot/issues/28
[15]: https://security.stackexchange.com/a/104991
[16]: https://github.com/bats-core/bats-core
[upstream]: https://github.com/JonasAlfredsson/docker-nginx-certbot
[pr373]: https://github.com/JonasAlfredsson/docker-nginx-certbot/pull/373#issuecomment-4106504007
[lego-providers]: https://go-acme.github.io/lego/dns/
