FROM nginx:1.31.10@sha256:a786635fd3c7b9a57ea089ab1c0713e510f3b548b65fe699ce3d59e4a926b37e
LABEL maintainer="emulatorchen"

# FORK: Python/certbot/Rust removed. Only the static lego binary is installed.
# Certbot is replaced by lego — a self-contained Go binary that covers all
# HTTP-01 (webroot) and DNS-01 challenges across 150+ providers.
#
# When merging from upstream (JonasAlfredsson/docker-nginx-certbot):
#   - Apply FROM version bump (this line) directly.
#   - Review COPY scripts/ and lines after it for nginx-layer changes.
#   - Skip all certbot/Python/Rust changes — they are intentionally removed.

ARG LEGO_VERSION=5.6.0
# The lego tarball each architecture must match. Set them with
# .github/lego_pins.sh --update <version>, which writes them only after gh has
# verified that lego's release workflow attested each tarball.
ARG LEGO_SHA256_AMD64=f02fc11b6f56b97e387fa7caa0268f86f5a336953b22458e6430e4651fea439a
ARG LEGO_SHA256_386=1e34109520ddc7c9cf0c269108d7a39e922ff40f394addd8f44682a2e7cfe3ed
ARG LEGO_SHA256_ARM64=34d87a6552d69390c4a4560237045c47713a8e148d899e16db0e97040894ed1f
ARG LEGO_SHA256_ARMV7=2cf63a16f080556e9b03c2b8aa049eabe9c986e65d46270726f86d5a376ef1b5
ARG TARGETARCH
ARG TARGETVARIANT

# Do a single run command to make the intermediary containers smaller.
RUN set -ex && \
# Install packages needed at runtime.
    apt-get update && \
    apt-get install -y --no-install-recommends \
        curl \
        openssl \
        procps \
    && \
# Install the static lego binary for certificate management.
    if [ "${TARGETARCH}" = "arm" ] && [ -n "${TARGETVARIANT}" ]; then \
        ARCH="arm${TARGETVARIANT}"; \
    else \
        ARCH=$(echo "${TARGETARCH:-$(uname -m)}" | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/armv7l/armv7/;s/armv6l/armv6/'); \
    fi && \
    TARBALL="lego_v${LEGO_VERSION}_linux_${ARCH}.tar.gz" && \
    case "${ARCH}" in \
        amd64) CHECKSUM="${LEGO_SHA256_AMD64}" ;; \
        386) CHECKSUM="${LEGO_SHA256_386}" ;; \
        arm64) CHECKSUM="${LEGO_SHA256_ARM64}" ;; \
        armv7) CHECKSUM="${LEGO_SHA256_ARMV7}" ;; \
        *) CHECKSUM="" ;; \
    esac && \
    if [ -z "${CHECKSUM}" ]; then echo "no pinned lego checksum for ${ARCH}" >&2; exit 1; fi && \
    curl -fsSL "https://github.com/go-acme/lego/releases/download/v${LEGO_VERSION}/${TARBALL}" \
        -o "/tmp/${TARBALL}" && \
    echo "${CHECKSUM}  /tmp/${TARBALL}" | sha256sum -c - && \
    tar -xz -C /usr/local/bin lego -f "/tmp/${TARBALL}" && \
    rm "/tmp/${TARBALL}" && \
    chmod +x /usr/local/bin/lego && \
# Remove curl — no longer needed at runtime.
    apt-get remove --purge -y curl && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* && \
# Create new directories and set correct permissions.
    mkdir -p /var/www/letsencrypt && \
    mkdir -p /etc/nginx/user_conf.d && \
    chown www-data:www-data -R /var/www && \
# Make sure there are no surprise config files inside the config folder.
    rm -f /etc/nginx/conf.d/*

# Copy in our "default" Nginx server configurations, which make sure that the
# ACME challenge requests are correctly forwarded to lego and then redirects
# everything else to HTTPS.
COPY nginx_conf.d/ /etc/nginx/conf.d/
# FORK: not present upstream. A split setup's server (NGINX_LEGO_ROLE) may run
# with /etc/nginx/conf.d on a tmpfs, which hides the file above; it restores it
# from this copy at start (restore_image_conf in util.sh).
COPY nginx_conf.d/ /usr/local/share/nginx-lego/conf.d/

# Copy in all our scripts and make them executable.
COPY scripts/ /scripts
RUN chmod +x -R /scripts && \
# Make so that the parent's entrypoint script is properly triggered (issue #21).
    sed -ri '/^if \[ "\$1" = "nginx" \] \|\| \[ "\$1" = "nginx-debug" \]; then$/,${s//if echo "$1" | grep -q "nginx"; then/;b};$q1' /docker-entrypoint.sh

# FORK: not present upstream. Do not drop when syncing this file; see UPSTREAM_SYNC.md.
# The container runs as the unprivileged nginx user (101:101), not root, so that
# user gets everything written at runtime. Group 0 gets the same access, so a
# platform that starts the container as its own uid in group 0 (OpenShift,
# Kubernetes runAsUser) works too. The 'user' line only matters to a root master
# and goes; the pid file stays in /run, which nginx now owns.
RUN set -e; \
    [ "$(id -u nginx):$(id -g nginx)" = "101:101" ] \
        || { echo "the nginx user is $(id -u nginx):$(id -g nginx), not 101:101" >&2; exit 1; }; \
    sed -i '/^[[:space:]]*user[[:space:]]/d' /etc/nginx/nginx.conf; \
    pid=$(sed -n 's/^[[:space:]]*pid[[:space:]][[:space:]]*\([^;]*\);.*/\1/p' /etc/nginx/nginx.conf); \
    [ "$(readlink -f "$(dirname "${pid}")")" = /run ] \
        || { echo "nginx writes its pid to '${pid}', not into /run" >&2; exit 1; }; \
    mkdir -p /etc/letsencrypt /etc/local_ca /var/cache/nginx /var/www/letsencrypt; \
    chown 101:0 /run; \
    chmod g+rwx /run; \
    chown -R 101:0 /etc/letsencrypt /etc/local_ca /var/cache/nginx /var/www/letsencrypt /etc/nginx/conf.d; \
    chmod -R g+rwX /etc/letsencrypt /etc/local_ca /var/cache/nginx /var/www/letsencrypt /etc/nginx/conf.d

# Create a volume to have persistent storage for the obtained certificates.

# --- CVE security pins (auto-managed) ---
# Each pin is a minimum source version: install the candidate, then check it.
RUN set -- \
        'bsdutils>=2.41.5-0+deb13u1' \
        'libaom3>=3.12.1-1+deb13u1' \
        'libblkid1>=2.41.5-0+deb13u1' \
        'libde265-0>=1.0.15-1+deb13u2' \
        'libexpat1>=2.8.2-1~deb13u1' \
        'libheif-plugin-dav1d>=1.19.8-1+deb13u1' \
        'libheif-plugin-libde265>=1.19.8-1+deb13u1' \
        'libheif1>=1.19.8-1+deb13u1' \
        'liblastlog2-2>=2.41.5-0+deb13u1' \
        'libmount1>=2.41.5-0+deb13u1' \
        'libsmartcols1>=2.41.5-0+deb13u1' \
        'libtiff6>=4.7.0-3+deb13u3' \
        'libuuid1>=2.41.5-0+deb13u1' \
        'login>=2.41.5-0+deb13u1' \
        'mount>=2.41.5-0+deb13u1' \
        'util-linux>=2.41.5-0+deb13u1' \
    && apt-get update \
    && apt-get install -y --no-install-recommends $(for pin; do echo "${pin%%>=*}"; done) \
    && for pin; do \
        v=$(dpkg-query -W -f='${source:Version}' "${pin%%>=*}") \
            && dpkg --compare-versions "$v" ge "${pin#*>=}" \
            || { echo "${pin%%>=*} ${v:-missing} is older than ${pin#*>=}" >&2; exit 1; }; \
    done \
    && rm -rf /var/lib/apt/lists/*
# --- end CVE security pins ---

VOLUME /etc/letsencrypt

# FORK: not present upstream. Do not drop when syncing this file; see UPSTREAM_SYNC.md.
# Applies and checks what the .trivyignore entries rely on; kept last so it also
# covers packages installed by earlier layers, including the CVE pin block.
RUN /scripts/cve_mitigations.sh debian

# FORK: run as the nginx user prepared above; see UPSTREAM_SYNC.md.
USER 101:101

# The Nginx parent Docker image already expose port 80, so we only need to add
# port 443 here.
EXPOSE 443

# Change the container's start command to launch our Nginx and lego
# management script.
CMD [ "/scripts/start_nginx_lego.sh" ]
