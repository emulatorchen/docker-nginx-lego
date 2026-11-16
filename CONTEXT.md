# docker-nginx-lego

A Docker image that runs Nginx and keeps its TLS certificates issued and renewed
with lego, for any number of sites and DNS providers.

## Language

### Image

**Image variant**:
One build of the image on a particular base: Debian, Alpine or Ubuntu.
_Avoid_: flavor, distro build

**Image user**:
The unprivileged account, uid and gid `101`, that every image variant runs as.
_Avoid_: nginx user, container user, root

**Base pin**:
The exact upstream image, tag and digest, an image variant is built from.
_Avoid_: base version

**Base refresh**:
Moving a base pin to the newer digest of the same tag to pick up upstream fixes.
_Avoid_: base upgrade (that changes the version), rebuild

### Certificates

**Certificate name**:
The `<name>` in `/etc/letsencrypt/live/<name>/`, whose suffixes choose the
challenge type, the DNS provider and the key type.
_Avoid_: domain, cert id

**Certificate group**:
The group, set with `NGINX_LEGO_CERT_GROUP`, that is given read access to the
issued certificates and keys.
_Avoid_: shared group, cert gid

**Consumer container**:
Another container that reads the certificates this image issues, such as a TLS
terminator in front of it.
_Avoid_: client, reader

### Releases

**Version tag**:
An immutable release tag: `lego<L>-nginx<N>`, and `lego<L>` for the first release
of a lego version, with `-alpine` or `-ubuntu` for those variants.
_Avoid_: release name, version

**Revision release**:
A re-release of an existing version tag, suffixed `-r<N>`.
_Avoid_: patch release, hotfix tag

**Floating tag**:
A tag every release moves: `latest`, `latest-alpine` and `latest-ubuntu`.
_Avoid_: moving tag, alias
