# Helper script to extract and verify the tag set on the Docker image.
# Expected tag formats:
#   lego4.33.0-nginx1.29.5        (base release)
#   lego4.33.0-nginx1.29.5-r1     (script-only revision)
#
# GITHUB_REF is passed in as the one and only argument.

if [ -z "${1}" ]; then
    >&2 echo "Input argument was empty"
    exit 1
fi

lego_version=$(echo "${1}" | sed -n -r -e 's&^refs/.+/lego([0-9]+\.[0-9]+\.[0-9]+)-nginx.*$&\1&p')
nginx_version=$(echo "${1}" | sed -n -r -e 's&^refs/.+/lego[0-9]+\.[0-9]+\.[0-9]+-nginx([1-9][0-9]*\.[0-9]+\.[0-9]+).*$&\1&p')
revision=$(echo "${1}"      | sed -n -r -e 's&^refs/.+/lego[0-9]+\.[0-9]+\.[0-9]+-nginx[0-9]+\.[0-9]+\.[0-9]+-r([0-9]+)$&\1&p')

if [ -n "${lego_version}" ] && [ -n "${nginx_version}" ]; then
    echo "LEGO_VERSION=${lego_version}"
    echo "NGINX_VERSION=${nginx_version}"
    echo "REVISION=${revision}"
else
    >&2 echo "Received the following input argument: '${1}'"
    >&2 echo "Could not extract lego/nginx versions from tag."
    >&2 echo "Expected format: lego<X.Y.Z>-nginx<X.Y.Z> or lego<X.Y.Z>-nginx<X.Y.Z>-r<N>"
    exit 1
fi
