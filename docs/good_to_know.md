# Good to Know

This document contains information about features and behavior that might be
good to know before you start using this image. Feel free to read it all, but I
recommend the first two sections for everyone.

## Initial Testing
In case you are just experimenting with setting this up I suggest you set the
environment variable `STAGING=1`, since this will change the Let's Encrypt
challenge URL to their staging one. This will not give you "*proper*"
certificates, but it has ridiculous high [rate limits][1] compared to the
non-staging [production certificates][2] so you can do more mistakes without
having to worry. You can also add `DEBUG=1` for more verbose logging to better
understand what is going on.

Include them like this:
```bash
docker run -it -p 80:80 -p 443:443 \
           --env CERTBOT_EMAIL=your@email.org \
           --env STAGING=1 \
           --env DEBUG=1 \
           emulator/docker-nginx-lego:latest
```

Note that when switching to production certificates you either need to remove the
staging certificates or issue a [force renewal](./advanced_usage.md#manualforce-renewal)
since by default lego will *not* request new certificates if any valid
(staging or production) certificates already exist.

## Creating a Server `.conf` File
As an example of a barebone (but functional) SSL server in Nginx you can
look at the file [`example_server.conf`](../examples/example_server.conf)
inside the [`examples/`](../examples) directory. By replacing '`yourdomain.org`'
with your own domain you can actually use this config to quickly test if things
are working properly. When doing this for real you should also change the
certificate paths'
["test-name"](#how-the-script-add-domain-names-to-certificate-requests) to
something more descriptive.

Place the modified config inside your [`user_conf.d/`](#the-user_confd-folder)
folder, and then run it as described
[in the main README](../README.md#run-with-docker-run). Let the container do
it's [magic](#diffie-hellman-parameters) for a while, and then try to visit
your domain. You should now be greeted with the string \
"`Let's Encrypt certificate successfully installed!`".

The files [already present](../src/nginx_conf.d) inside the container's config
folder are there to handle redirection to HTTPS for all incoming requests that
are not part of the lego challenge requests, so be careful to not overwrite
these unless you know what you are doing.

## The `user_conf.d` Folder
Nginx will, by default, load any file ending with `.conf` from within the
`/etc/nginx/conf.d/` folder. However, this image makes use of one important
[configuration file](../src/nginx_conf.d) which need to be present (unless you
know how to replace it with your own), and host mounting a local folder to
the aforementioned location would shadow this important file.

To solve this problem I therefore suggest you host mount a local folder to
`/etc/nginx/user_conf.d/` instead, and a part of the management scripts will
[create symlinks][3] from `conf.d/` to the files in `user_conf.d/`. This way
we give users a simple way to just start the container, without having to build
a local image first, while still giving them the opportunity to keep doing it
in the old way like how [`@staticfloat`'s image][5] worked.

The files you mount there are read by the container's user, uid `101`, so they
have to be readable by it; world-readable files, the usual default, are fine.


## Running as Non-Root
From `lego5.6.0-nginx1.31.8` on, every image runs as the unprivileged user
`101:101`, the `nginx` user of the official Nginx images (the Ubuntu image
creates it with the same numbers). Nginx's master and workers, lego and every
script run as that user; there is no root process and no root variant of the
image. Everything the container writes at runtime belongs to that user:
`/etc/letsencrypt`, `/etc/local_ca`, `/var/www/letsencrypt`, `/etc/nginx/conf.d`,
`/var/cache/nginx` and the pid file in `/run`. Until you are ready to migrate,
`lego5.4.1-nginx1.31.8` and older tags keep running as root.

### Your certificate storage
A new named volume is created from the image and already belongs to uid 101, so
it needs nothing. A volume or host directory written by an older image belongs
to root. At startup the container checks that it can write its storage and, if
it cannot, stops before Nginx starts and logs the path and the command that fixes
it:

```bash
docker run --rm --user 0 -v <volume-or-dir>:/etc/letsencrypt \
  emulator/docker-nginx-lego chown -R 101:101 /etc/letsencrypt
```

For a host directory, `sudo chown -R 101:101 <dir>` on the host does the same.
Prepare a new host directory the same way before the first start, since a
directory Docker creates for a bind mount belongs to root.

### Files you mount
Everything Nginx and lego open is now opened as uid 101 instead of root: your
`user_conf.d` files and whatever they include, certificates and keys outside
`/etc/letsencrypt`, DNS credential (`.ini`) files, and any log file you point
Nginx at. Make them readable by uid 101 (world-readable is enough for configs;
give credential files to uid 101 and keep them `0600`), and make log files and
their directories writable. Content Nginx serves was already read by the `nginx`
user before, so it is unaffected.

### Ports 80 and 443
An unprivileged process may bind ports below 1024 only when the kernel allows it.
Docker allows it in every container it starts
(`net.ipv4.ip_unprivileged_port_start=0`), so the image needs no capability and
gets none; dropping all capabilities works. Two cases need a setting:

- Host networking (`--network host`, `network_mode: host`): the host's own
  setting applies, 1024 by default. Set `net.ipv4.ip_unprivileged_port_start=80`
  on the host, or publish the ports instead.
- Another container runtime: set the same sysctl for the container, for example
  `--sysctl net.ipv4.ip_unprivileged_port_start=0`, or in Kubernetes through
  `securityContext.sysctls` (it is a safe sysctl).

### Your own `nginx.conf`
The image's `nginx.conf` no longer has a `user` line, which only applies when the
master runs as root. A `nginx.conf` you mount keeps working, since Nginx ignores
its `user` line with a warning; remove it to silence that. Keep the `pid` file in
`/run`, which the `nginx` user owns.

### Kubernetes and platform-assigned users
```yaml
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 101
    runAsGroup: 101
    fsGroup: 101            # the certificate volume becomes writable by the pod
    sysctls:                # only if the runtime does not allow ports below 1024
      - name: net.ipv4.ip_unprivileged_port_start
        value: "0"
  containers:
    - name: nginx-lego
      image: emulator/docker-nginx-lego:lego5.6.0-nginx1.31.8
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

The image's `USER` is numeric, so `runAsNonRoot` can verify it. A platform that
starts the container as a uid of its own choosing, such as OpenShift's restricted
policy or a different `runAsUser`, works as long as that uid is in group `0`,
which OpenShift arranges by default: everything the container writes is writable
by group `0` as well.

### What it means for security
Nothing in the container runs as root, lego and the scripts included. The other
side of that: Nginx's workers now run as the same user as lego, where before only
the root master and lego could read the DNS credentials and the ACME account key.
Give the image DNS API tokens with the least power your provider allows (limited
to the zone and, where possible, to TXT records), so a token leaked through a
compromised Nginx can do as little as possible.

### `docker exec` and images built on top
`docker exec` runs as uid 101 as well. An image built `FROM` this one starts as
`101:101`, so switch to `USER root` for steps that need root, such as installing
packages, and back to `USER 101:101` at the end; see
[Build It Yourself](../README.md#build-it-yourself).


## How the Script add Domain Names to Certificate Requests
The included script will go through all configuration files (`*.conf*`) it
finds inside Nginx's `/etc/nginx/conf.d/` folder, and create requests from the
file's content. In every unique file it will find any line that says:

```
ssl_certificate_key /etc/letsencrypt/live/test-name/privkey.pem;
```

and only extract the part which here says "`test-name`". This is the value that
will be used as the cert name by lego, so while you may set basically any
name you want here I suggest you keep it descriptive for your own sake.

> ADVANCED: It is possible to add keywords to this certificate name in order
> to use [specific algorithms](./advanced_usage.md#multi-certificate-setup) or
> use a specific [DNS provider](./lego_providers.md).

After this the script will find all the lines that contain `server_name` and
make a list of all the domain names that exist on the same line. So a file
containing something like this:

```
server {
    listen              443 ssl;
    server_name         yourdomain.org www.yourdomain.org;
    ssl_certificate_key /etc/letsencrypt/live/test-name/privkey.pem;
    ...
}

server {
    listen              443 ssl;
    server_name         sub.yourdomain.org;
    ssl_certificate_key /etc/letsencrypt/live/test-name/privkey.pem;
    ...
}
```

will share the same certificate file (i.e. the "test-name" certificate), and
all listed domain variants will be included as valid [alt names][15]. It is
also possible to split these sever blocks into two separate config files,
as the script will keep track of the "test-name" value across the scans and just
add any additional findings to it. So in the end we will get a single request
that looks something like this:

```
lego --domains yourdomain.org --domains www.yourdomain.org --domains sub.yourdomain.org ...
```

The scripts are quite powerful when it comes to customizability for defining
what should be included in the request, but this is considered a more advanced
usecase that may be further studied in the
[Override `server_name`](./advanced_usage.md#override-server_name) section of
the Advanced Usage document.

`include` directives are followed while reading a file, exactly as Nginx itself
does when it loads its configuration. This matters if you factor shared TLS
settings out into a snippet, which is a common way to avoid repeating the same
six lines in every server block:

```
server {
    listen      443 ssl;
    server_name yourdomain.org;
    include     conf.d/snippets/ssl_yourdomain.inc;
}
```

Here the certificate lives in the snippet and the domain name lives in the
server block. Neither file contains both halves, so neither would yield a
complete request on its own — the snippet has a certificate but no domains, and
the server block has domains but no certificate. Because includes are resolved
first, the two are seen together and the request is built correctly.

Relative include paths resolve against the Nginx prefix, which is `/etc/nginx`.
Since everything you put in `user_conf.d/` is symlinked into `conf.d/`, a snippet
you mount at `user_conf.d/snippets/ssl_yourdomain.inc` is reachable as
`conf.d/snippets/ssl_yourdomain.inc`, as above; an absolute path works too. Globs
such as `include conf.d/snippets/*.inc;` are expanded, again matching Nginx.

> **Name your snippets so they do not match `*.conf*`.** Anything matching that
> pattern under `conf.d/` — or under `user_conf.d/`, which is the same file by
> another name, since everything there is symlinked into `conf.d/` — is scanned
> as a configuration file in its own right, and is therefore *not* inlined into
> the files that include it. A snippet scanned alone has certificate references
> but no `server_name`, which yields a certificate with no domains. `.inc` is a
> good choice.

That exclusion is deliberate, and it is also why an aggregating layout keeps
working. If `00-main.conf` contains only `include conf.d/sites/*.conf;`, each
site file is still parsed separately, exactly as before — so every site keeps its
own certificate with its own domains. Were those inlined, all the certificates
and all the domains would land in one bucket together and each certificate would
be requested for every site's hostnames.

Note that discovery still starts from the `*.conf*` files in `/etc/nginx/conf.d/`.
A snippet is read because something includes it, not because it was found by the
scan, so a snippet that nothing includes is not picked up.

Furthermore, we support wildcard domain names, but that requires you to use an
authenticator capable of DNS-01 challenges, and more info about that may be
found in the [lego_providers.md](./lego_providers.md) document.

If you need a certificate that no server block references at all — because
something other than this Nginx serves it — see
[Certificates Nginx Does Not Serve](./advanced_usage.md#certificates-nginx-does-not-serve).


## ECDSA and RSA Certificates
[ECDSA (or ECC)][16] certificates use a newer encryption algorithm than the well
established RSA certificates, and are supposedly more secure while being much
smaller. The downside with these is that they are not supported by all clients
yet, but if you don't expect to serve anything outisde the "Modern" row in
[Mozillas compatibility table][17] you should not hesitate to configure lego
to request these types of certificates.

This is achieved by setting the [environment variable](../README.md#optional)
`USE_ECDSA=1` (the default since version 3.0.1), and you can optionally tune
which [curve][18] to use with `ELLIPTIC_CURVE`. If you already have RSA
certificates downloaded you will either have to wait until they expire, or
[force](./advanced_usage.md#manualforce-renewal) a renewal, before this change
takes affect.

With this option you will create only ECDSA certificates for all of your server
configurations, however, I should mention that there is a way to configure
Nginx to serve both ECDSA and RSA certificates at the same time, but this
is explained further in the
[Advanced Usage](./advanced_usage.md#multi-certificate-setup) document.

> :warning: If you are using ciphers that depend on RSA they will be
> [silently disabled](https://github.com/JonasAlfredsson/docker-nginx-certbot/issues/247#issuecomment-2128717110)
> if only ECDSA certificates are available.


## Renewal Check Interval
This container will automatically start a lego certificate renewal check
after the time duration that is defined in the environmental variable
`RENEWAL_INTERVAL` has passed. After lego has done its stuff, the code will
return and wait the defined time before triggering again.

This process is very simple, and is just a `while [ true ];` loop with a `sleep`
at the end:

```bash
while [ true ]; do
    # Run lego...
    sleep "$RENEWAL_INTERVAL"
done
```

So when setting the environmental variable, it is possible to use any string
that is recognized by `sleep`, e.g. `3600` or `60m` or `1h`. Read more about
which values that are allowed in its [manual][4].

The default is `8d`, since this allows for multiple retries per month, while
keeping the output in the logs at a very low level. If nothing needs to be
renewed lego won't do anything, so it should be no problem setting it lower
if you want to. The only thing to think about is to not to make it longer than
one month, because then you would [miss the window][6] where lego would deem
it necessary to update the certificates.

## Diffie-Hellman Parameters
Regarding the Diffie-Hellman parameter it is recommended that you have one for
your server, and in Nginx you define it by including a line that starts with
`ssl_dhparam` in the server block (see
[`example_server.conf`](../examples/example_server.conf)). However, you can
make a config file without it and Nginx will work just fine with ciphers that
don't rely on the Diffie-Hellman key exchange ([more info about ciphers][7]).

The larger you make these parameters the longer it will take to generate them.
I was unlucky and it took me 65 minutes to generate a 4096 bit parameter on a
really old 3.0GHz CPU. This will vary **greatly** between runs as some
randomness is involved. A 2048 bit parameter, which is still secure today, can
probably be calculated in about 1-3 minutes on a modern CPU (this process will
only have to be done once, since one of these parameters is good for the rest
of your website's lifetime). To modify the size of the parameter you may set the
`DHPARAM_SIZE` environment variable. Default is `2048` if nothing is provided.

It is also possible to have **all** your server configs point to **the same**
Diffie-Hellman parameter on disk. There is no negative effects in doing this for
home use ([source 1][8] & [source 2][9]). For persistence you should place it
inside the dedicated folder `/etc/letsencrypt/dhparams/`, which is inside the
predefined Docker [volume](../README.md#volumes). There is, however, no
requirement to do so, since a missing parameter will be created where the
config file expects the file to be. But this would mean that the script will
have to re-create these every time you restart the container, which may become
a little bit tedious.

You can also create this file on a completely different (faster?) computer and
just mount/copy the created file into this container. This is perfectly fine,
since it is nothing "private/personal" about this file. The only thing to
think about in that case would perhaps be to use a folder that is not under
`/etc/letsencrypt/`, since that would otherwise cause a double mount, and to make
the file readable by the container's user, uid `101`.

## Binaries Removed for Unfixed CVEs
Some components carry CVEs that have no fixed package in the Debian image yet,
and nothing in this image uses them, so the images leave them out instead of
waiting for a fix. Each one is listed with its reason in
[`.trivyignore`](../.trivyignore), and
[`cve_mitigations.sh`](../src/scripts/cve_mitigations.sh) applies and checks the
changes as the last step of every image build:

- `infocmp` (Debian and Ubuntu images) and `nsenter` (Debian image) are
  deleted, and `/etc/dpkg/dpkg.cfg.d/cve-path-excludes` keeps later installs
  and upgrades from putting them back.
- No binary is setuid or setgid. On Debian and Ubuntu, `dpkg-statoverride --list`
  shows the overrides that keep it that way across upgrades.

In an image built on top of this one, running
`/scripts/cve_mitigations.sh <debian|ubuntu|alpine> --check` as root (after
`USER root` in your Dockerfile) tells you
whether these still hold. To get one of the tools back, delete the exclude file or the
override (`dpkg-statoverride --remove <path>`) and reinstall the package.

## Help Migrating from `@staticfloat`'s Image
The two images are not that different when it comes to building/running, since
this repository was originally a fork. So just like in `@staticfloat`'s setup
you need to get your own `*.conf` files into the container's
`/etc/nginx/conf.d/` folder, and then you should be able to start this one
just like you did with his.

This can either be done by copying your own files into the container at
[build time](../README.md#build-it-yourself), or you can mount a local folder to
[`/etc/nginx/user_conf.d/`](#the-user_confd-folder) and
[run it directly](../README.md#run-with-docker-run). In the former case you need
to make sure you do not accidentally overwrite the two files present in this
repository's [`nginx_conf.d/`](../src/nginx_conf.d) folder, since these are
required in order for lego to request certificates.

The only obligatory environment variable for starting this container is the
[`CERTBOT_EMAIL`](../README.md#required) one, just like in `@staticfloat`'s
case, but I have exposed a [couple of more](../README.md#optional) that can be
changed from their defaults if you like. Then there is of course any environment
variables read by the [parent container][11] as well, but those are probably
not as important.

If you were using [templating][12] before, you should probably look into
["template" files][13] used by the Nginx parent container, since this is not
something I have personally implemented in mine.





[1]: https://letsencrypt.org/docs/staging-environment/
[2]: https://letsencrypt.org/docs/rate-limits/
[3]: https://github.com/JonasAlfredsson/docker-nginx-certbot/commit/91f8ecaa613f1e7c0dc4ece38fa8f38a004f61ec
[4]: http://man7.org/linux/man-pages/man1/sleep.1.html
[5]: https://github.com/staticfloat/docker-nginx-certbot
[6]: https://community.letsencrypt.org/t/solved-how-often-to-renew/13678
[7]: https://raymii.org/s/tutorials/Strong_SSL_Security_On_nginx.html
[8]: https://security.stackexchange.com/questions/70831/does-dh-parameter-file-need-to-be-unique-per-private-key
[9]: https://security.stackexchange.com/questions/94390/whats-the-purpose-of-dh-parameters

[11]: https://github.com/nginxinc/docker-nginx
[12]: https://github.com/staticfloat/docker-nginx-certbot#templating
[13]: https://github.com/docker-library/docs/tree/master/nginx#using-environment-variables-in-nginx-configuration-new-in-119
[14]: https://go-acme.github.io/lego/
[15]: https://www.digicert.com/faq/subject-alternative-name.htm
[16]: https://sectigostore.com/blog/ecdsa-vs-rsa-everything-you-need-to-know/
[17]: https://wiki.mozilla.org/Security/Server_Side_TLS
[18]: https://security.stackexchange.com/questions/31772/what-elliptic-curves-are-supported-by-browsers/104991#104991
