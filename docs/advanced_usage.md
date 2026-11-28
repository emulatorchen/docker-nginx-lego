# Advanced Usage

This document contains information about features that are deemed "advanced",
and will most likely require that you read some of the actual code to fully
understand what is happening.

## Signal handling

The container configures handlers for the following signals:

 - `SIGINT`, `SIGQUIT`, `SIGTERM` - Shutdown the child processes (nginx and the
   [sleep timer](./good_to_know.md#renewal-check-interval)) and exit the
   container.
 - `SIGHUP` - Rerun [`run_lego.sh`](../src/scripts/run_lego.sh) and tell
   nginx to test and reload the configuration files (i.e. `nginx -t` followed
   by `nginx -s reload`). See [Manual/Force Renewal](#manualforce-renewal),
   [Controlling NGINX][20], and [Changing configuration][21] for more details.
 - `SIGUSR1` - Tell nginx to reopen log files (i.e. `nginx -s reopen`). See
   [Controlling NGINX][20] and [Rotating Log-files][22] for more details.

Signals can be sent to the container by using the `docker kill` command (or
`docker compose kill` when using Docker Compose). For example, to send a
`SIGHUP` signal to the container run:

```bash
docker kill --signal=HUP <container_name>
```

## Manual/Force Renewal
It might be of interest to manually trigger a renewal of the certificates, and
that is why the [`run_lego.sh`](../src/scripts/run_lego.sh) script is
possible to run standalone at any time from within the container.

However, the preferred way of requesting a reload of all the configuration files
is to send in a [`SIGHUP`][1] to the container:

```bash
docker kill --signal=HUP <container_name>
```

This will terminate the [sleep timer](./good_to_know.md#renewal-check-interval)
and make the renewal loop start again from the beginning, which includes a lot
of other checks than just the certificates.

While this will be enough in the majority of the cases, it might sometimes be
necessary to **force** a renewal of the certificates even though lego thinks
it could keep them for a while longer (like when [this][2] happened). It is
therefore possible to add "force" as an argument, when calling the
[`run_lego.sh`](../src/scripts/run_lego.sh) script, to have it append
the `--force` flag to the requests made.

```bash
docker exec -it <container_name> /scripts/run_lego.sh force
```

This will request new certificates regardless of when they are set to expire.

> :warning: Using "force" will make new requests for **all** you certificates,
  so don't run it too often since there are some limits to requesting
  [production certificates][3].


## Override `server_name`
Nginx allows you to to do a lot of stuff in the [`server_name` declaration][18],
but since the scripts inside this image compose certificate requests from the
same lines we are severely limited in what is possible to define on those lines.
For example the line `server_name mail.*` would produce a certificate request
for the domain name `mail.*`, which is not valid.

However, to combat this limitation it is possible to define a special comment
(`lego_domain:`) on the same line in order to override what the scripts will
pick up. So in this contrived example

```bash
server {
    listen              443 ssl;
    ssl_certificate_key /etc/letsencrypt/live/test-name/privkey.pem;

    server_name         yourdomain.org;
    server_name         www.yourdomain.org; # lego_domain:*.yourdomain.org
    server_name         sub.yourdomain.org; # lego_domain:*.yourdomain.org
    server_name         mail.*;             # lego_domain:*.yourdomain.org
    server_name         ~^(?<user>.+)\.yourdomain\.org$;
    ...
}
```

we will end up with a certificate request which looks like this:

```
lego --cert-name "test-name" ... --domains yourdomain.org --domains *.yourdomain.org
```

The fist server name will be picked up as usual, while the following three will
be shadowed by the domain in the comment, i.e. `*.yourdomain.org` (and duplicate
names will be removed in the final request).

The last server name is special, in that it is a regex and those always start
with a `~`. Since we know we will never be able to create a valid request from
a name which start with that character they will always be ignored by the
script (a trailing comment will take precedence instead of being ignored).
A more detailed example of this can be viewed in
[`example_server_overrides.conf`](../examples/example_server_overrides.conf).

Important to remember is that here we define a wildcard domain name (the `*`
in the the `*.yourdomain.org`), and that requires you to use an authenticator
capable of DNS-01 challenges, and more info about that may be found in the
[lego_providers.md](./lego_providers.md) document.


## Multi-Certificate Setup
This is a continuation of the
[RSA and ECDSA](./good_to_know.md#ecdsa-and-rsa-certificates) section from
the [Good to Know](./good_to_know.md) document, where it was briefly mentioned
that it is actually possible to have Nginx serve both of these certificate
types at the same time, thus expanding support for semi-old devices again while
also allowing the most up to date encryption to be used. [The setup][4] is a
bit more complicated, but the
[`example_server_multicert.conf`](../examples/example_server_multicert.conf)
file should be configured so you should only have to edit the "yourdomain.org"
statements at the top.

How this works is that Nginx is able to [load multiple certificate files][5]
for each server block, and you then configure the cipher suites in an order
that prefers ECDSA certificates. The scripts running inside the container look for some (case insensitive)
variant of these strings in the cert name from the
[`ssl_certificate_key`](./good_to_know.md#how-the-script-add-domain-names-to-certificate-requests)
path:

- `-rsa`
- `.rsa`
- `-ecc`
- `.ecc`
- `-ecdsa`
- `.ecdsa`

and makes a certificate request with the correct type set. See the
[actual commit][6] for more details, but what you need to know is that if
these options are found they override the [`USE_ECDSA`](../README.md#optional)
environment variable.


## Certificates Nginx Does Not Serve
Certificate discovery works by reading the Nginx configuration: it looks for
[`ssl_certificate_key`](./good_to_know.md#how-the-script-add-domain-names-to-certificate-requests)
paths and pairs them with the `server_name` entries around them. That is exactly
right for every certificate Nginx itself serves, but it cannot see a certificate
this container is meant to obtain on behalf of *something else* — a separate TLS
terminator sitting in front of Nginx, or a service that reads the PEM files
directly off a shared volume. There is no server block to find, so nothing is
requested and nothing is renewed.

Historically the only way around this was to add a dummy server block whose sole
purpose was to be noticed by discovery. That works, but it is invisible to anyone
reading the config later, and deleting it as dead weight silently ends renewal.

Declare such certificates explicitly instead, with the `LEGO_EXTRA_CERTS`
environment variable:

```
LEGO_EXTRA_CERTS="<cert_name>=<domain>[,<domain>...][;<cert_name>=...]"
```

Entries are separated by `;`, and the domains within an entry by `,`. For
example:

```yaml
environment:
  - LEGO_EXTRA_CERTS=edge-proxy=example.org,www.example.org;api.dns-route53=*.api.example.org
```

The certificate is written to `/etc/letsencrypt/live/<cert_name>/`, and the name
may carry the same suffixes as one parsed out of a config file: a
`dns-<provider>` token to select which credentials are used
([Certificate Naming Convention](../README.md#certificate-naming-convention)),
or a key-type token ([Multi-Certificate Setup](#multi-certificate-setup)).
Unlike a name taken from a config file, it is restricted to letters, digits,
`.`, `_` and `-`, and may not begin with a `.` — the name is a directory
component, and here you do not see the full path you are writing.

Three details worth knowing:

- Naming a certificate that discovery already found is harmless. The domains are
  merged into the existing entry rather than duplicated, so you can list one
  redundantly without producing a second request.
- A malformed entry is reported and skipped, not fatal. One typo must not stop
  every other certificate in the list from renewing.
- The value may be written across several lines for readability. Each entry
  still has to end with its `;` — a newline is treated as whitespace, not as a
  separator:

  ```yaml
  environment:
    - |
      LEGO_EXTRA_CERTS=edge-proxy=example.org,www.example.org;
      api.dns-route53=*.api.example.org
  ```

  A domain that does not look like a host name is reported and skipped, so a
  missing `;` is caught rather than quietly welding two entries together.

When [`USE_LOCAL_CA`](#local-ca) is enabled, these certificates are issued by the
local CA exactly like discovered ones, so whatever serves them has a file to open
during development. Note that the local CA and lego are alternatives rather than
stages: when `USE_LOCAL_CA=1` lego does not run at all, so in a normal
deployment an extra certificate does not exist on disk until lego's first run
completes. If the service that consumes it cannot start without the file, give it
a self-signed placeholder of your own, or let it retry.


## Share Certificates With Another Container
lego writes every private key readable only by the user that runs it (`0600`,
inside `0700` directories). That keeps the keys safe, but it also means another
container that needs the same certificates (a TLS terminator in front of Nginx,
a mail server, an MQTT broker) can only read them by running as that same user
or as root.

Set `NGINX_LEGO_CERT_GROUP` to a group name or numeric gid to give that group
read access instead:

| Path | Becomes |
|---|---|
| `certificates/`, `live/` and every `live/<cert_name>/` | `0750`, owned by the group |
| `certificates/*.crt` and `certificates/*.key` | `0640`, owned by the group |
| files the [local CA](#local-ca) writes into `live/<cert_name>/` | `0640`, owned by the group |
| `dhparams/` and `dhparams/*.pem` | `0750` and `0640`, owned by the group |

DH parameters are public values; they are shared so that a server in its own
container ([below](#run-nginx-and-lego-in-separate-containers)) can use them.
Nothing else changes. The ACME account key (`accounts/`), lego's metadata
(`*.json`), DNS credential files (`*.ini`) and `archive/` keep the permissions
they have, and no symlink is ever followed. The group is applied
after every issue and renewal, and once at startup for certificates that
already exist. Unset, nothing changes at all.

A process can only hand a file to a group it belongs to, so this container needs
the group too. Give both containers the same supplementary group:

```yaml
services:
  nginx:
    image: emulator/docker-nginx-lego:latest
    group_add: ["10443"]
    environment:
      - CERTBOT_EMAIL=your@email.org
      - NGINX_LEGO_CERT_GROUP=10443
    volumes:
      - nginx_secrets:/etc/letsencrypt
      - ./user_conf.d:/etc/nginx/user_conf.d:ro

  proxy:
    image: example/tls-proxy:latest
    user: "1000:1000"
    group_add: ["10443"]
    volumes:
      - nginx_secrets:/etc/letsencrypt:ro

volumes:
  nginx_secrets:
```

With `docker run` the same is `--group-add 10443`, and in Kubernetes it is
`securityContext.supplementalGroups: [10443]`. The gid does not have to exist
in either image. If this container is not a member of the group, it logs an
error saying so and the keys stay private.

Two details:

- Mount the volume at `/etc/letsencrypt` in the other container as well. The
  files in `live/<cert_name>/` are absolute symlinks into
  `/etc/letsencrypt/certificates/`, so they only resolve at that path.
- The other container can read any file in the volume that is readable by
  everyone, such as a DNS credentials file created `0644`. Keep credential files
  `0600`, or outside the shared volume with
  [`CERTBOT_DNS_CREDENTIALS_DIR`](../README.md#advanced).


## Run Nginx and lego in Separate Containers
In one container, Nginx's workers run as the same user as lego, so code running
in a worker can read the DNS credentials and the ACME account key
([why](./good_to_know.md#what-it-means-for-security)). Splitting the image into
two containers, both from the same image, takes them out of Nginx's reach. It is
opt-in: without `NGINX_LEGO_ROLE` the image works as one container, as always.

| | Issuer (`NGINX_LEGO_ROLE=issuer`) | Server (`NGINX_LEGO_ROLE=server`) |
|---|---|---|
| Runs | lego and the renewal loop; no Nginx, no ports | Nginx only |
| User | the image user `101:101` | another uid, for example `102:0` |
| Certificate store | read-write, its owner | read-only (`:ro`) |
| DNS credentials | mounted here only | none |
| Can read | everything in the store | certificates, keys and DH parameters, through the certificate group |

The issuer refuses to start without `NGINX_LEGO_CERT_GROUP`, since the server
could not read a key otherwise. The server refuses to start, and later to
reload, if it runs as root or as the issuer's uid (the owner of the store), if
it can read the ACME account or a DNS credentials file, or if it can write the
store (the store is not mounted `:ro`), and says how to fix it.

After every renewal pass the issuer writes a mark into the store. The server
looks at it every `NGINX_LEGO_RELOAD_CHECK` seconds (default `60`) and reloads
Nginx once per renewal, unless `nginx -t` fails.

The whole setup is in
[`examples/docker-compose-split.yml`](../examples/docker-compose-split.yml):

```yaml
services:
  issuer:
    image: emulator/docker-nginx-lego:latest
    group_add: ["10443"]
    environment:
      - CERTBOT_EMAIL=your@email.org
      - NGINX_LEGO_ROLE=issuer
      - NGINX_LEGO_CERT_GROUP=10443
    volumes:
      - letsencrypt:/etc/letsencrypt
      - acme_challenges:/var/www/letsencrypt
      - ./user_conf.d:/etc/nginx/user_conf.d:ro
      - ./dns_credentials:/etc/letsencrypt/credentials:ro
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]

  server:
    image: emulator/docker-nginx-lego:latest
    user: "102:0"
    group_add: ["10443"]
    environment:
      - NGINX_LEGO_ROLE=server
    ports:
      - 80:80
      - 443:443
    volumes:
      - letsencrypt:/etc/letsencrypt:ro
      - acme_challenges:/var/www/letsencrypt:ro
      - ./user_conf.d:/etc/nginx/user_conf.d:ro
    read_only: true
    tmpfs: [/run, /var/cache/nginx, /etc/nginx/conf.d, /tmp]
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    depends_on: [issuer]

volumes:
  letsencrypt:
  acme_challenges:
```

What to know:

- **DNS-01** works in the issuer exactly as in one container: the certificate
  name suffix, `LEGO_DEFAULT_PROVIDER` and the `.ini` files in
  `CERTBOT_DNS_CREDENTIALS_DIR`. Mount the credentials into the issuer only, as
  above with `CERTBOT_DNS_CREDENTIALS_DIR=/etc/letsencrypt/credentials`.
- **HTTP-01** needs the webroot shared: lego writes the challenges into
  `/var/www/letsencrypt` in the issuer, and the server answers them from the same
  volume. A DNS-01-only setup does not need that volume.
- **The server's read-only filesystem**: `/run`, `/var/cache/nginx`,
  `/etc/nginx/conf.d` and `/tmp` must be writable, here as tmpfs. The image's own
  file in `/etc/nginx/conf.d` (the port 80 redirect and the challenge path) is
  put back there at every start.
- **Signals**: `SIGHUP` to the issuer runs a renewal pass now; the server reloads
  once it sees the new mark. Send `SIGUSR1` (reopen logs) to the server.
- **Moving from one container**: keep your current container and volume as the
  issuer (add `NGINX_LEGO_ROLE=issuer` and `NGINX_LEGO_CERT_GROUP`, drop its
  ports), add the server, and add the webroot volume to both if you use HTTP-01.
  The store needs no `chown`: the issuer keeps the image user.
- **Kubernetes**: the same two containers in one pod, the server with
  `runAsUser: 102`, `readOnlyRootFilesystem: true` and `emptyDir` volumes for the
  four writable paths, both with `supplementalGroups: [10443]`.


## Use Custom ACME URL
There are two variables available at the top of the
[`run_lego.sh`](../src/scripts/run_lego.sh) script:

- `CERTBOT_PRODUCTION_URL`
- `CERTBOT_STAGING_URL`

which are used to define which server lego will try to contact when
requesting new certificates. These variables have default values, but it is
possible to override them by defining environment variables with the same name.
This then enables you to redirect lego to another custom URL if you, for
example, are running your own custom ACME server.


## Local CA
During the development phase of a website you might be testing stuff on a
computer that either does not have a DNS record pointing to itself or perhaps
it does not have internet access at all. Since lego has both of these as
requirements to function properly it was previously impossible to use this
image during those particular situations.

That is why the [`run_local_ca.sh`](../src/scripts/run_local_ca.sh) script was
created, since this makes it possible to use a
[local (self-signed) certificate authority][10] that can issue website
certificates without relying on any external service or internet connection.
It also enables us to issue certificates that are valid for `localhost` and/or
IP addresses like `::1`, which are otherwise [impossible][7] for lego to
create.

> You can also use this solution if your intend to deploy behind a CDN and you
> do not need a "real" certificate in order to encrypt the communication
> between the origin server and the CDN's infrastructure. But please read
> this entire section before going forward with that kind of setup.

To enable the usage of this local CA you just set
[`USE_LOCAL_CA=1`](../README.md#advanced), and this will then trigger the
execution of the [`run_local_ca.sh`](../src/scripts/run_local_ca.sh) script
instead of the [`run_lego.sh`](../src/scripts/run_lego.sh) one when it is
time to renew the certificates. This script, when run, will always overwrite
any previous keys and certificates, so alternating between the use of a local
CA and lego without first emptying the `/etc/letsencrypt` folder is **not**
supported.

The script is designed to mimic lego's certificate layout as closely as reasonable, so the
keys/certs created are placed in the same locations as lego would have. This
means that you only have to edit the `server_name` in your server configuration
files to include the variant that you want for your local instance (e.g.
`localhost`) and you should be all set.

However, if you navigate to your site at this point you will run into an error
named similar to Firefox's `SEC_ERROR_UNKNOWN_ISSUER`, which just means that
your browser does not recognize the CA that has signed your site's certificate.
This is expected (since we just created our own local CA), but at this point
the connection is using all the fancy HTTPS stuff, and is thus "secure", so you
can just ignore this warning if you want.

Another solution is to [import][9] the local CA's certificate created by this
script into your browser, thus making this a known certificate authority and
any of its signed certs trusted. What this file is, and how to obtain it, is
explained further in the [next section](#files-and-folders).


### Files and Folders
For the local CA to operate a couple of things are needed:

- `caPrivkey.pem`: The private key used by the CA -> this is the most secret
                   thing that (in a real CA's case) must be protected at all
                   costs.
- `caCert.pem`: The public certificate part of the CA -> needed by all clients
                in order to trust any other certificates this CA signs.
- `serial.txt`: A long random hexadecimal number that is incremented by one
                every time a new certificate is signed by the CA.
- `index.txt`: Keeps a [record][8] of all certificates that have been issued
               by this CA.
- `new_certs/`: Folder where a copy of all the newly signed certificates are
                placed.

All of these are created automatically by the script inside the folder defined
by [`LOCAL_CA_DIR`](../src/scripts/run_local_ca.sh) (which defaults to
`/etc/local_ca`), so by host mounting this folder you will be able to see all
these files. By then taking the `caCert.pem` and [importing][9] it in your
browser you will be able to visit these sites without the error stating that
the certificate is signed by an unknown authority.

An important thing to know is that these files are only created if they do
not exist. What this enables is an even more advanced usecase where you might
already have a private key and certificate that you trust on your devices, and
you would like to continue using it for the websites you host as well. Read
more about this in the [next section](#creating-a-custom-ca).


### Creating a Custom CA
The validity period for the automatically created CA is only 30 days by
default, and the reason for this is to deter people from using this solution
blindly in production. While it is possible to quickly change this through the
`LOCAL_CA_ROOT_CERT_VALIDITY` variable, there are security concerns regarding
managing your own certificate authority which should be thought through before
doing this in a production environment.

Nevertheless, as was mentioned in the previous section it is possible to supply
the [`run_local_ca.sh`](../src/scripts/run_local_ca.sh) script with a local
certificate authority that has been created manually by you that you want to
trust on multiple other devices.
Basically all you need to do is to host mount your custom private key and
certificate to the `LOCAL_CA_DIR`, and the script will use these instead of
the short lived automatically created ones. Just make sure the files are named
in accordance to [what the script expects](#files-and-folders), and if any one
of these components are missing they will be created the first time the service
is started.

> As of now a password protected private key is not supported.

I did not find it trivial to create a **well configured** CA, so if you want
to go this route I really suggest that you read up on what you are doing and
making sure all settings are correctly tuned for your usecase.

There is a [lot][11] of [high-level][12] information [available][13] in regards
to how to create your own CA, but what I found most confusing was exactly what
was expected to be inside the [`openssl.cnf`][14] file that is necessary to
have when running most of the OpenSSL commands. The configuration that is
present inside the [`run_local_ca.sh`](../src/scripts/run_local_ca.sh) script
should be quite minimalistic for what we need, while still providing the
[strict settings][15] that some clients need else they will reject these
custom certificates.

The most comprehensive guide I have found is the [OpenSSL Cookbook][17],
which goes into great detail about basically everything OpenSSL is able to do,
along with [this post][16] which summarizes the settings needed for different
certificate types. With these two you should be able to make an informed
configuration in case you want to create your own custom certificate authority,
and you may of course take a look at the commands used in the
[`generate_ca()`](../src/scripts/run_local_ca.sh) function to help you on your
way of creating your own files.

When the long term CA is in place you can probably tune the `RENEWAL_INTERVAL`
variable to equal something slightly less than the hard-coded `90d` expiry
time of the leaf certificates created. This is the expiry time recommended by
Let's Encrypt (and perhaps [soon mandated][19]), and since the renewal script
_should_ always be successful you only need to run it just before the expiry
time. You can, of course, run it more often than that, but it will not yield
and special benefits.






[1]: https://github.com/JonasAlfredsson/docker-nginx-certbot/commit/bf2c1354f55adffadc13b1f1792e205f9dd25f86
[2]: https://community.letsencrypt.org/t/revoking-certain-certificates-on-march-4/114864
[3]: https://letsencrypt.org/docs/rate-limits/
[4]: https://medium.com/hackernoon/rsa-and-ecdsa-hybrid-nginx-setup-with-letsencrypt-certificates-ee422695d7d3
[5]: https://scotthelme.co.uk/hybrid-rsa-and-ecdsa-certificates-with-nginx/
[6]: https://github.com/JonasAlfredsson/docker-nginx-certbot/commit/9195bf02cb200dcec8206b46da971734b1d6669f
[7]: https://letsencrypt.org/docs/certificates-for-localhost/
[8]: https://pki-tutorial.readthedocs.io/en/latest/cadb.html
[9]: https://support.securly.com/hc/en-us/articles/360008547993-How-to-Install-Securly-s-SSL-Certificate-in-Firefox-on-Windows
[10]: https://gist.github.com/Soarez/9688998
[11]: https://gist.github.com/fntlnz/cf14feb5a46b2eda428e000157447309
[12]: https://github.com/llekn/openssl-ca
[13]: https://jamielinux.com/docs/openssl-certificate-authority/create-the-root-pair.html
[14]: https://github.com/llekn/openssl-ca/blob/master/openssl.cnf
[15]: https://derflounder.wordpress.com/2019/06/06/new-tls-security-requirements-for-ios-13-and-macos-catalina-10-15/
[16]: https://superuser.com/questions/738612/openssl-ca-keyusage-extension/1248085#1248085
[17]: https://www.feistyduck.com/library/openssl-cookbook/online/ch-openssl.html
[18]: https://nginx.org/en/docs/http/server_names.html
[19]: https://www.globalsign.com/en-ae/blog/google-90-day-certificate-validity-requires-automation
[20]: https://docs.nginx.com/nginx/admin-guide/basic-functionality/runtime-control/#controlling-nginx
[21]: https://nginx.org/en/docs/control.html#reconfiguration
[22]: https://nginx.org/en/docs/control.html#logs
