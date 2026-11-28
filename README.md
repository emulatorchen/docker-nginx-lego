# docker-nginx-lego

> [!WARNING]
> **Two changes to know before you pull:**
> 1. **From `lego5.6.0-nginx1.31.8` the image no longer runs as root.** Every image
>    (Debian, Alpine and Ubuntu, on every architecture) runs as the unprivileged user
>    `101:101`; `lego5.4.1-nginx1.31.8` and older still run as root. **An existing
>    setup needs a one-time migration:** read
>    [Upgrading to the Non-Root Image](#upgrading-to-the-non-root-image).
> 2. **From `lego5.6.0-nginx1.31.10`, Nginx and lego can
>    also run in separate containers.** This is opt-in: a single container works as
>    before unless you set `NGINX_LEGO_ROLE`. One thing changes for everyone who sets
>    `NGINX_LEGO_CERT_GROUP`: the Diffie-Hellman parameters are shared with that group
>    too. Read [Splitting Nginx and lego](#splitting-nginx-and-lego).
>
> Not sure which setup to run? See [Choose Your Setup](#choose-your-setup).

Automatically create and renew website SSL certificates using the
[Let's Encrypt][1] free certificate authority and its client [*lego*][2].
Built on top of the [official Nginx Docker images][9] (Debian, Alpine, and Ubuntu 24.04),
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
- [Debian, Alpine, and Ubuntu 24.04](./docs/dockerhub_tags.md) images built for [multiple architectures][14].
- **No Python dependency** — lego is a static Go binary; images are significantly smaller.
- **150+ DNS providers** supported natively by lego (see [lego provider list][lego-providers]).
- **Runs without root**: Nginx, lego and every script run as the unprivileged user `101:101` ([details](./docs/good_to_know.md#running-as-non-root)).
- Can [share the certificates](./docs/advanced_usage.md#share-certificates-with-another-container) with another container through a group, without handing out root.
- Can run Nginx and lego in [separate containers](#splitting-nginx-and-lego), so Nginx never holds the DNS credentials (opt-in).



# Acknowledgments and Thanks

This container requests SSL certificates from [Let's Encrypt][1], which they
provide for the absolutely bargain price of free! If you like what they do,
please [donate][3].

This repository is a fork of [`JonasAlfredsson/docker-nginx-certbot`][upstream],
which itself was originally forked from [`@staticfloat`][5] and
[`@henridwyer`][4]. The certbot-to-lego migration was [encouraged by the
upstream author][pr373] — thanks for the excellent foundation.



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


## Choose Your Setup
There are three ways to run this image. The difference that matters is what an
attacker reaches if a bug in Nginx lets them run code inside an Nginx worker
([why this is not theoretical](./docs/good_to_know.md#what-it-means-for-security)).

| Setup | Tags | Runs as | A compromised Nginx worker can reach | How |
|---|---|---|---|---|
| Root image (old) | `lego5.4.1-nginx1.31.8` and older | root, workers as `nginx` | the certificates and keys | stay on that tag; it gets no further fixes |
| One container (default) | `lego5.6.0-nginx1.31.8` and newer, `latest*` | `101:101` | the certificates and keys, **the DNS credentials, the ACME account, and the store, to change it** | [Upgrading to the Non-Root Image](#upgrading-to-the-non-root-image) |
| Split (opt-in) | `lego5.6.0-nginx1.31.10` and newer | issuer `101:101`, server `102:0` | the certificates, keys and DH parameters, read-only | [Splitting Nginx and lego](#splitting-nginx-and-lego) |

Pick the split when Nginx faces the internet and your DNS tokens can do real
damage (a token for your whole DNS zone, say). One container is simpler and is
fine with tokens limited to the zone's TXT records.

## Upgrading to the Non-Root Image
Starting with `lego5.6.0-nginx1.31.8` the container runs as uid `101`, gid `101`
(the `nginx` user of the official Nginx images) instead of root. Nginx, lego and
every script run as that user; nothing in the image needs root any more. Not
ready yet? Stay on `lego5.4.1-nginx1.31.8` until you are.

What can break in an existing setup, and how to fix it:

| Your setup | What happens | Fix (once) |
|---|---|---|
| Certificates in a volume or host directory written by an older image | The container stops at startup and logs the path it cannot write and the command below | `docker run --rm --user 0 -v <volume-or-dir>:/etc/letsencrypt emulator/docker-nginx-lego chown -R 101:101 /etc/letsencrypt`, or `sudo chown -R 101:101 <dir>` on the host |
| DNS credential files (`.ini`) the new user cannot read | DNS-01 requests fail with "not readable by this container's user" | `chown 101 <file>`, and keep it `0600` |
| Other files you mount for Nginx: config files, certificates or keys outside `/etc/letsencrypt`, log files | Nginx cannot open them and fails to start or reload | make them readable by uid 101 (log files, and their folders, writable) |
| `network_mode: host`, or a container runtime that blocks ports below 1024 | Nginx cannot bind ports 80/443 ("Permission denied") | allow unprivileged ports with `--sysctl net.ipv4.ip_unprivileged_port_start=0` (with host networking, set that sysctl on the host) |
| An image built `FROM` this one that installs packages | `apt-get` / `apk` fail | `USER root` before the installs, `USER 101:101` at the end |
| Your own mounted `nginx.conf` | Keeps working | remove its `user` line; it now only logs a warning |
| `docker exec` into the container | Runs as uid 101 | nothing to do |

A new, empty named volume needs nothing: Docker creates it owned by uid 101.
Platforms that force their own uid in group `0` (OpenShift, Kubernetes
`runAsUser`) work too. Kubernetes settings and the details behind each row are
in [Running as Non-Root](./docs/good_to_know.md#running-as-non-root).

> [!IMPORTANT]
> Nginx's workers now run as the same user as lego, so a bug that lets an
> attacker run code in a worker also exposes your DNS credentials and ACME
> account key. Read [What it means for security](./docs/good_to_know.md#what-it-means-for-security):
> use least-privilege DNS tokens, and run the container with
> `--cap-drop ALL --security-opt no-new-privileges`, or split Nginx and lego as
> below.

## Splitting Nginx and lego
Starting with `lego5.6.0-nginx1.31.10`, the same image
can run as two containers: an **issuer** that runs lego and keeps the
certificate store, and a **server** that runs Nginx as another user and can read
nothing but the certificates. It is opt-in.

> [!NOTE]
> **Why opt-in, not the default.** Some hosts can only run an app as one
> container: some NAS app catalogs and one-click templates install a single
> container and offer no way to add a second one that shares its volumes.
> Making the split the default would break those setups, so one container stays
> the default and the split is there for setups that can run two.
>
> **A hardened Nginx: the idea, not the image (yet).** The server follows what a
> hardened Nginx image is for: Nginx alone, as its own unprivileged user, on a
> read-only filesystem, with no capabilities and no secrets in reach. It does not
> switch to a hardened Nginx image such as Docker Hardened Images or Chainguard.
> Those have no shell for the server's reload check, cover fewer architectures
> than this image (no `386` or `arm/v7`), and some need a registry login to
> pull. A server that reloads on a signal from the issuer could use such an
> image later
> ([#268](https://github.com/emulatorchen/docker-nginx-lego/issues/268)).

What changes:

| | One container | Split (`NGINX_LEGO_ROLE`) |
|---|---|---|
| Reads the DNS credentials | Nginx's workers and lego (both uid `101`) | lego only, in the issuer |
| Can use the ACME account | Nginx's workers and lego | lego only |
| Can change `/etc/letsencrypt` | Nginx's workers and lego | lego only; the server mounts it read-only |
| Nginx's own filesystem | writable | read-only, with four small tmpfs |
| Containers | 1 | 2, from the same image |

**If you stay on one container**, nothing changes except one permission: with
`NGINX_LEGO_CERT_GROUP` set, `dhparams/` becomes `0750` and `dhparam.pem` `0640`,
owned by that group, like the certificates already are. DH parameters are public
values; a split server has to read them. Without `NGINX_LEGO_CERT_GROUP`, nothing
changes at all.

**To switch** an existing single container:

1. Keep the container and its `/etc/letsencrypt` volume: it becomes the issuer.
   Add `NGINX_LEGO_ROLE=issuer`, `NGINX_LEGO_CERT_GROUP=10443` (any unused gid) and
   `group_add: ["10443"]`, and remove its `ports`.
2. Add the server: the same image with `NGINX_LEGO_ROLE=server`, `user: "102:0"`,
   `group_add: ["10443"]`, the same volume mounted `:ro`, your `user_conf.d` mounted
   `:ro`, `read_only: true` with `tmpfs` for `/run`, `/var/cache/nginx`,
   `/etc/nginx/conf.d` and `/tmp`, and the `ports`.
3. HTTP-01 certificates also need a volume at `/var/www/letsencrypt` in both
   containers (read-only in the server). For DNS-01 keep the credential files
   mounted in the issuer only; the server needs nothing.
4. Start the issuer first, then the server. If something is set up so that the
   server could reach the issuer's secrets (wrong uid, credentials readable, store
   writable), it refuses to start and logs the fix.

No `chown` is needed: the issuer keeps the user `101:101`. **To go back**, remove
the server, drop `NGINX_LEGO_ROLE` from the issuer and give it its ports again.
The whole setup is in [`examples/docker-compose-split.yml`](./examples/docker-compose-split.yml),
and the details are in
[Run Nginx and lego in Separate Containers](./docs/advanced_usage.md#run-nginx-and-lego-in-separate-containers).


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
- `LEGO_EXTRA_CERTS`: Certificates to obtain and renew that no server block references, because something other than this Nginx serves them. Format `<cert_name>=<domain>[,<domain>...][;<cert_name>=...]`. See [Certificates Nginx Does Not Serve](./docs/advanced_usage.md#certificates-nginx-does-not-serve).
- `NGINX_LEGO_CERT_GROUP`: A group name or gid given read access to the issued certificates and keys, so another container can use them. The container must be a member of that group (`--group-add`). See [Share Certificates With Another Container](./docs/advanced_usage.md#share-certificates-with-another-container).
- `NGINX_LEGO_ROLE`: `all` (default) runs Nginx and lego in one container. `issuer` and `server` split them into two containers from the same image, so Nginx never holds the DNS credentials or the ACME account. See [Run Nginx and lego in Separate Containers](./docs/advanced_usage.md#run-nginx-and-lego-in-separate-containers).
- `NGINX_LEGO_RELOAD_CHECK`: In the server of a split setup, seconds between looks for a renewal by the issuer (default: `60`)
- `NGINX_INCLUDE_MAX_DEPTH`: How many levels of `include` directives to follow when reading a config file (default: `10`)
- `NGINX_PREFIX`: Base directory used to resolve relative `include` paths (default: `/etc/nginx`, matching the image's nginx prefix)
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

The container reads the file as uid `101`, so give it to that user and keep it
private: `chown 101 cloudflare.ini && chmod 600 cloudflare.ini`.

See [lego providers documentation](./docs/lego_providers.md) for the full list
of providers and their required environment variables.

**Legacy `dns-multi` format** (backward compatible):
```ini
# /etc/letsencrypt/multi.ini
dns_multi_provider = cloudflare
CLOUDFLARE_DNS_API_TOKEN = your-token-here
```


## Volumes
- `/etc/letsencrypt`: Stores the obtained certificates and the Diffie-Hellman parameters. Must be writable by uid `101`.


## Run with `docker run`
Create your own [`user_conf.d/`](./docs/good_to_know.md#the-user_confd-folder)
folder and place all of your custom server config files in there. Then start
the container:

```bash
docker run -it -p 80:80 -p 443:443 \
           --cap-drop ALL --security-opt no-new-privileges \
           --env CERTBOT_EMAIL=your@email.org \
           -v nginx_secrets:/etc/letsencrypt \
           -v $(pwd)/user_conf.d:/etc/nginx/user_conf.d:ro \
           --name nginx-lego emulator/docker-nginx-lego:lego5.6.0-nginx1.31.8
```

To keep the certificates in a host directory instead of the `nginx_secrets`
volume, create it for the container's user first: `mkdir nginx_secrets && sudo
chown 101:101 nginx_secrets`, then mount `$(pwd)/nginx_secrets`. A directory
Docker creates on its own belongs to root, and the container would refuse it.

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
FROM emulator/docker-nginx-lego:lego5.6.0-nginx1.31.8
COPY conf.d/* /etc/nginx/conf.d/
```

The image runs as `101:101`. A `RUN` step that needs root, such as installing a
package, has to switch to root and back:

```Dockerfile
FROM emulator/docker-nginx-lego:lego5.6.0-nginx1.31.8
USER root
RUN apt-get update && apt-get install -y --no-install-recommends jq && rm -rf /var/lib/apt/lists/*
USER 101:101
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
