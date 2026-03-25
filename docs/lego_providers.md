# Lego DNS Providers

lego supports [150+ DNS providers][lego-providers] for DNS-01 challenges. This
document explains how to configure them.

## HTTP-01 vs DNS-01

By default this container uses **HTTP-01** (webroot) to validate domain ownership.
Lego serves the challenge file from `/var/www/letsencrypt`, which nginx forwards
via the `.well-known/acme-challenge/` location in
[`redirector.conf`](../src/nginx_conf.d/redirector.conf).

**DNS-01** is required when:
- You want **wildcard certificates** (e.g. `*.yourdomain.org`)
- Your server is not publicly reachable on port 80
- Your service is on a private LAN

DNS-01 proves domain ownership by adding a TXT record to your DNS zone. Let's
Encrypt only needs to perform DNS lookups — no inbound connection needed.


## Preparing the Container for DNS-01 Challenges

Create a credentials file for your DNS provider. lego uses **environment
variables** for credentials. Store them as `KEY=VALUE` pairs in a `.ini` file:

```ini
# /etc/letsencrypt/cloudflare.ini
CLOUDFLARE_DNS_API_TOKEN=your-api-token-here
```

The file name must match the provider suffix in the cert name. For a cert
named `example.com.dns-cloudflare`, the credentials file is `cloudflare.ini`.

Place the file at `$CERTBOT_DNS_CREDENTIALS_DIR/<provider>.ini` — the variable
defaults to `/etc/letsencrypt`.

Then reference it in your nginx server block:

```nginx
server {
    listen              443 ssl;
    server_name         example.com *.example.com;
    ssl_certificate     /etc/letsencrypt/live/example.com.dns-cloudflare/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/example.com.dns-cloudflare/privkey.pem;
    ...
}
```

The `dns-cloudflare` suffix tells lego to use Cloudflare DNS-01 and read
`cloudflare.ini` for credentials.


## Provider Credentials Reference

Find the exact environment variable names for your provider in the
[lego DNS provider documentation][lego-providers].

Common providers:

| Provider | Cert suffix | Credentials file | Key env var |
|---|---|---|---|
| Cloudflare | `.dns-cloudflare` | `cloudflare.ini` | `CLOUDFLARE_DNS_API_TOKEN` |
| DigitalOcean | `.dns-digitalocean` | `digitalocean.ini` | `DO_AUTH_TOKEN` |
| Route53 (AWS) | `.dns-route53` | env vars only | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` |
| DuckDNS | `.dns-duckdns` | `duckdns.ini` | `DUCKDNS_TOKEN` |
| FreeMyIP | `.dns-freemyip` | `freemyip.ini` | `FREEMYIP_TOKEN` |
| Hetzner | `.dns-hetzner` | `hetzner.ini` | `HETZNER_API_KEY` |
| Gandi | `.dns-gandiv5` | `gandiv5.ini` | `GANDIV5_PERSONAL_ACCESS_TOKEN` |
| PowerDNS | `.dns-pdns` | `pdns.ini` | `PDNS_API_URL`, `PDNS_API_KEY` |
| OVH | `.dns-ovh` | `ovh.ini` | `OVH_ENDPOINT`, `OVH_APPLICATION_KEY`, etc. |

For the complete list see the [lego provider documentation][lego-providers].


## Using a DNS-01 Provider by Default

Set `LEGO_DEFAULT_PROVIDER` to apply a DNS provider to all certificates that
do not have an explicit `.dns-<provider>` suffix in their cert name:

```bash
docker run ... -e LEGO_DEFAULT_PROVIDER=cloudflare ...
```

`CERTBOT_AUTHENTICATOR` is accepted as a backward-compatible alias (the
`dns-` prefix is stripped automatically if present).


## Cert-Specific Provider Override

Include the provider name in the cert path to use a different provider for
individual certificates while keeping a different default:

```nginx
# Uses the global default provider (e.g. cloudflare) for most certs, but
# Route53 for this specific cert:
ssl_certificate_key /etc/letsencrypt/live/mysite.dns-route53/privkey.pem;
```

Combine with key-type suffixes:
```nginx
ssl_certificate_key /etc/letsencrypt/live/mysite.dns-cloudflare.rsa/privkey.pem;
```


## Unique Credentials Files

Add a numeric suffix to the cert name to use separate credentials files for
the same provider (useful when hosting multiple customers on different accounts):

```nginx
# First customer — uses cloudflare_1.ini
ssl_certificate_key /etc/letsencrypt/live/customer1.dns-cloudflare_1/privkey.pem;

# Second customer — uses cloudflare_2.ini
ssl_certificate_key /etc/letsencrypt/live/customer2.dns-cloudflare_2/privkey.pem;
```

The suffix may not contain `.` or `-` (they are used as separators).


## Route53 Special Case

AWS Route53 credentials come from environment variables (not a `.ini` file),
following the standard AWS credential chain:

```bash
docker run ... \
  -e AWS_ACCESS_KEY_ID=AKIA... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -e AWS_REGION=us-east-1 \
  ...
```

No credentials file is needed. The cert suffix `.dns-route53` is sufficient.


## DNS Propagation Timeout

lego uses provider-specific environment variables to control the propagation
wait time. For example:

```ini
# cloudflare.ini
CLOUDFLARE_DNS_API_TOKEN=your-token
CLOUDFLARE_PROPAGATION_TIMEOUT=120
```

Check the [lego provider documentation][lego-providers] for the exact variable
name for your provider. The old `CERTBOT_DNS_PROPAGATION_SECONDS` env var is
not supported — use the lego-native variable in your `.ini` file instead.


## Legacy dns-multi Format

Credentials files using the old `dns-multi` format are fully backward
compatible:

```ini
# /etc/letsencrypt/multi.ini  (cert suffix: .dns-multi)
dns_multi_provider = cloudflare
CLOUDFLARE_DNS_API_TOKEN = your-token-here
```

```ini
# /etc/letsencrypt/multi_2.ini  (cert suffix: .dns-multi_2)
dns_multi_provider = digitalocean
DO_AUTH_TOKEN = your-do-token
```

These files continue to work without any changes.


[lego-providers]: https://go-acme.github.io/lego/dns/
