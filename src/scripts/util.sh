#!/bin/bash

: ${DATE_FORMAT_STRING:="+%Y/%m/%d %T"}

# Helper function used to output messages in a uniform manner.
#
# $1: The log level to print.
# $2: The message to be printed.
log() {
    echo "$(date "${DATE_FORMAT_STRING}") [${1}] ${2}"
}

# Helper function to output debug messages to STDOUT if the `DEBUG` environment
# variable is set to 1.
#
# $1: String to be printed.
debug() {
    if [ 1 = "${DEBUG}" ]; then
        log "debug" "${1}"
    fi
}

# Helper function to output informational messages to STDOUT.
#
# $1: String to be printed.
info() {
    log "info" "${1}"
}

# Helper function to output warning messages to STDOUT, with bold yellow text.
#
# $1: String to be printed.
warning() {
    (set +x; tput -Tscreen bold
    tput -Tscreen setaf 3
    log "warning" "${1}"
    tput -Tscreen sgr0)
}

# Helper function to output error messages to STDERR, with bold red text.
#
# $1: String to be printed.
error() {
    (set +x; tput -Tscreen bold
    tput -Tscreen setaf 1
    log "error" "${1}"
    tput -Tscreen sgr0) >&2
}

# Helper function to print each folder created as a new DEBUG log line.
#
# $1: Directory to create.
mkdir_log() {
    while IFS="" read -r line; do
        debug "${line}"
    done < <(mkdir -vp "${1}")
}

# Returns 0 if the parameter is an IPv4 or IPv6 address, 1 otherwise.
# Can be used as `if is_ip "$something"; then`.
#
# $1: the parameter to check if it is an IP address.
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}

# Returns 0 if the parameter is an IPv4 address, 1 otherwise.
# Can be used as `if is_ipv4 "$something"; then`.
#
# $1: the parameter to check if it is an IPv4 address.
is_ipv4() {
    [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# Returns 0 if the parameter is an IPv6 address, 1 otherwise.
# Can be used as `if is_ipv6 "$something"; then`.
#
# This comes from the amazing answer from David M. Syzdek
# on stackoverflow: https://stackoverflow.com/a/17871737
#
# $1: the parameter to check if it is an IPv6 address.
is_ipv6() {
    [[ "${1,,}" =~ ^(([0-9a-fA-F]{1,4}:){7,7}[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,7}:|([0-9a-fA-F]{1,4}:){1,6}:[0-9a-fA-F]{1,4}|([0-9a-fA-F]{1,4}:){1,5}(:[0-9a-fA-F]{1,4}){1,2}|([0-9a-fA-F]{1,4}:){1,4}(:[0-9a-fA-F]{1,4}){1,3}|([0-9a-fA-F]{1,4}:){1,3}(:[0-9a-fA-F]{1,4}){1,4}|([0-9a-fA-F]{1,4}:){1,2}(:[0-9a-fA-F]{1,4}){1,5}|[0-9a-fA-F]{1,4}:((:[0-9a-fA-F]{1,4}){1,6})|:((:[0-9a-fA-F]{1,4}){1,7}|:)|fe80:(:[0-9a-fA-F]{0,4}){0,4}%[0-9a-zA-Z]{1,}|::(ffff(:0{1,4}){0,1}:){0,1}((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])|([0-9a-fA-F]{1,4}:){1,4}:((25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9])\.){3,3}(25[0-5]|(2[0-4]|1{0,1}[0-9]){0,1}[0-9]))$ ]]
}

# FORK: this function does not exist upstream. Do not overwrite this file from
# upstream wholesale; see UPSTREAM_SYNC.md.
#
# Emit a configuration file with every 'include' directive replaced by the
# contents of the file(s) it names, recursively, the way Nginx itself resolves
# includes when it loads its configuration. Every parse_* function below reads
# its input through here.
#
# Without this, a server block that keeps its 'ssl_certificate' lines in an
# included snippet is invisible to certificate discovery: the snippet holds the
# certificate but no 'server_name', while the file including it holds the
# 'server_name' but no certificate, so neither half parses on its own. Splitting
# vhosts into shared snippets is a common Nginx layout, and it silently disabled
# renewal for every certificate declared that way.
#
# Relative include paths resolve against the Nginx prefix. Globs are expanded,
# and a quoted path containing spaces resolves correctly. An include matching
# nothing is skipped rather than fatal, since Nginx tolerates an empty glob and
# a cosmetic config problem must not become a failed renewal.
#
# Where this deliberately differs from Nginx — all inherited from the line-based
# parsing the parse_* functions have always used:
#   - 'include' must begin the line; a directive sharing the line ahead of it is
#     not seen.
#   - the terminating ';' must be on the same line as the 'include'.
#   - anything following that ';' on the same line is dropped with it.
#
# An include whose target certificate discovery ALREADY scans on its own is not
# inlined. Everything matching '*.conf*' under the conf.d directory is parsed as
# a configuration in its own right, so inlining it here would fuse its
# certificates with this file's server names and vice versa — 'parse_config_file'
# pairs every certificate in its input with every domain in it. An aggregating
# layout such as 'include conf.d/sites/*.conf;' would then request every site's
# hostnames on every site's certificate. Snippets are the case this function
# exists for, and a snippet is precisely a file discovery does NOT scan alone.
#
# $1: Path to a Nginx configuration file.
# $2: Current recursion depth (internal; callers omit it).
# $3: ':'-separated paths already open in this chain (internal; callers omit it).
nginx_config_stream() {
    local conf_file="${1}"
    local depth="${2:-0}"
    local seen="${3:-}"
    local max_depth="${NGINX_INCLUDE_MAX_DEPTH:-10}"

    # A non-numeric value makes the comparison below fail with a usage error,
    # and because it is an 'if' condition that reads as false — which would
    # remove the recursion limit entirely and let a self-including file run the
    # stack out and kill the renewal loop.
    if ! [[ "${max_depth}" =~ ^[0-9]+$ ]]; then
        warning "NGINX_INCLUDE_MAX_DEPTH='${max_depth}' is not a number; falling back to 10" >&2
        max_depth=10
    fi

    # '-gt' rather than '-ge': the top-level file is depth 0, so a limit of 0
    # must still read that file and simply follow none of its includes. With
    # '-ge' a limit of 0 would emit nothing at all and every certificate would
    # silently disappear.
    if [ "${depth}" -gt "${max_depth}" ]; then
        # stderr deliberately: this function's stdout IS the configuration every
        # parse_* function reads, so a log line on stdout would be parsed as
        # though it were configuration.
        warning "Reached include depth limit at '${conf_file}'; not descending further" >&2
        return 0
    fi

    if [ ! -r "${conf_file}" ]; then
        # Absent is fine and silent: Nginx tolerates an include glob matching
        # nothing, and so do we. Present but unreadable is a different thing —
        # a broken mount, or a file this container's user (uid 101) may not
        # read — and staying quiet would hide every certificate in it. sed
        # used to report this itself before the parse_* functions read through
        # this function.
        if [ -e "${conf_file}" ]; then
            warning "Cannot read '${conf_file}'; any certificate declared in it will be missed" >&2
        fi
        return 0
    fi

    # Refuse to re-open a file already open further up this chain. The depth
    # limit alone bounds how DEEP we go, not how much work we do: a handful of
    # files that glob-include each other multiply combinatorially and would keep
    # the renewal loop busy indefinitely, requesting nothing and reporting
    # nothing. Nginx rejects circular includes outright; we simply stop.
    # No '--': busybox realpath, which is what the Alpine image ships, does not
    # accept it and exits non-zero even when it printed the right answer — which
    # would quietly reduce this to a literal string comparison on exactly the
    # image where every conf.d entry is a symlink. Every path reaching here is
    # absolute, so there is no leading-dash to guard against anyway.
    local real_path
    real_path="$(realpath "${conf_file}" 2>/dev/null)"
    [ -n "${real_path}" ] || real_path="${conf_file}"
    case ":${seen}:" in
        *":${real_path}:"*)
            warning "Include cycle reaching '${conf_file}'; not descending further" >&2
            return 0
            ;;
    esac
    seen="${seen:+${seen}:}${real_path}"

    # Roots holding files certificate discovery scans on its own; see the header
    # comment. Both spellings matter: 'symlink_user_configs' mirrors every
    # user_conf.d file into conf.d, and discovery scans with 'find -L', so one
    # file is reachable under two names. Excluding only the conf.d spelling
    # would let 'include user_conf.d/sites/*.conf;' inline files that are also
    # scanned standalone, which is the fusing this exclusion exists to prevent.
    local nginx_prefix="${NGINX_PREFIX:-/etc/nginx}"
    nginx_prefix="${nginx_prefix%/}"

    # Every directory whose '*.conf*' files discovery scans on its own.
    # '/etc/nginx/conf.d' is hardcoded in run_lego.sh, run_local_ca.sh and
    # auto_enable_configs, so it is scanned whatever NGINX_PREFIX says; and
    # everything under user_conf.d is symlinked into it, which makes one file
    # reachable under two names. The prefix-derived pair is included as well so
    # a relocated prefix is covered, and each root's resolved form because
    # conf.d entries are symlinks and discovery follows them with 'find -L'.
    local -a scanned_roots=()
    local root resolved
    for root in "${nginx_prefix}/conf.d" "${nginx_prefix}/user_conf.d" \
                "/etc/nginx/conf.d" "/etc/nginx/user_conf.d"; do
        scanned_roots+=("${root}")
        resolved="$(realpath "${root}" 2>/dev/null)"
        if [ -n "${resolved}" ] && [ "${resolved}" != "${root}" ]; then
            scanned_roots+=("${resolved}")
        fi
    done

    local line include_arg include_path include_base real_include skip_include
    local -a matches
    while IFS= read -r line || [ -n "${line}" ]; do
        if [[ "${line}" =~ ^[[:space:]]*include[[:space:]]+([^\;]+)\; ]]; then
            include_arg="${BASH_REMATCH[1]}"
            # Trim trailing whitespace, then any surrounding quotes Nginx allows.
            include_arg="${include_arg%"${include_arg##*[![:space:]]}"}"
            include_arg="${include_arg#\"}"; include_arg="${include_arg%\"}"
            include_arg="${include_arg#\'}"; include_arg="${include_arg%\'}"

            # Relative paths resolve against the Nginx prefix. Use the
            # normalised copy: a prefix written with a trailing slash would
            # otherwise produce '/etc/nginx//conf.d/...', which no longer
            # prefix-matches the exclusion roots computed below and would let an
            # aggregating include through.
            if [[ "${include_arg}" != /* ]]; then
                include_arg="${nginx_prefix}/${include_arg}"
            fi

            # Expand the glob WITHOUT word splitting, so that a quoted path
            # containing spaces still resolves. compgen -G prints one match per
            # line, and prints nothing when the pattern matches no file.
            matches=()
            while IFS= read -r include_path; do
                matches+=("${include_path}")
            done < <(compgen -G "${include_arg}" 2>/dev/null)

            # No glob match: the path may still name a file directly.
            if [ "${#matches[@]}" -eq 0 ] && [ -f "${include_arg}" ]; then
                matches=("${include_arg}")
            fi

            for include_path in "${matches[@]}"; do
                if [ ! -f "${include_path}" ]; then
                    continue
                fi

                # Leave anything discovery parses standalone to discovery. See
                # the header comment: inlining it would pair its certificates
                # with this file's domains and produce wrong SANs. Both the
                # written path and its resolved form are checked, since the same
                # file is reachable as itself and as a symlink under conf.d.
                include_base="${include_path##*/}"
                if [[ "${include_base}" == *.conf* ]]; then
                    real_include="$(realpath "${include_path}" 2>/dev/null)"
                    [ -n "${real_include}" ] || real_include="${include_path}"
                    skip_include=0
                    for root in "${scanned_roots[@]}"; do
                        if [[ "${include_path}" == "${root}"/* ]] \
                            || [[ "${real_include}" == "${root}"/* ]]; then
                            skip_include=1
                            break
                        fi
                    done
                    if [ "${skip_include}" -eq 1 ]; then
                        debug "Not inlining '${include_path}': discovery parses it separately" >&2
                        continue
                    fi
                fi

                nginx_config_stream "${include_path}" "$((depth + 1))" "${seen}"
            done
        else
            printf '%s\n' "${line}"
        fi
    done < "${conf_file}"
}

# Find lines that contain 'ssl_certificate_key', and try to extract a name from
# each of these file paths. Each keyfile must be stored at the default location
# of /etc/letsencrypt/live/<cert_name>/privkey.pem, otherwise we ignore it since
# it is most likely not a certificate that is managed by lego.
#
# $1: Path to a Nginx configuration file.
parse_cert_names() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*ssl_certificate_key\s+\/etc/letsencrypt/live/(.*)/privkey.pem;.*&\1&p' | xargs -n1 echo | uniq
}

# Nginx will answer to any domain name that is written on the line which starts
# with 'server_name'. A server block may have multiple domain names defined on
# this line, and a config file may have multiple server blocks. This method will
# therefore try to extract all domain names and add them to the certificate
# request being sent. Some things to think about:
# * Wildcard names must use DNS authentication, else the challenge will fail.
# * Possible overlappings. This method will find all 'server_names' in a .conf
#   file inside the conf.d/ folder and attach them to the request. If there are
#   different primary domains in the same .conf file it will cause some weird
#   certificates. Should however work fine but is not best practice.
# * If the following comment "# lego_domain:<replacement_domain>" is present at
#   the end of the line it will be printed twice in such a fashion that it
#   encapsulate the server names that should be replaced with this one instead,
#   like this:
#       1. lego_domain:*.example.com
#       2. lego_domain:www.example.com
#       3. lego_domain:sub.example.com
#       4. lego_domain:*.example.com
#   The legacy "certbot_domain:" prefix is also accepted for backward compatibility.
# * Unlike the other similar functions this one will not perform "uniq" on the
#   names, since that would prevent the feature explained above.
#
# $1: Path to a Nginx configuration file.
parse_server_names() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*server_name\s+([^;]*);\s*#?(\s*(lego_domain|certbot_domain):[^[:space:]]+)?.*$&\2 \1 \2&p' | xargs -n1 echo
}

# Return all unique "ssl_certificate_key" file paths.
#
# $1: Path to a Nginx configuration file.
parse_keyfiles() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*ssl_certificate_key\s+(.*);.*&\1&p' | xargs -n1 echo | uniq
}

# Return all unique "ssl_certificate" file paths.
#
# $1: Path to a Nginx configuration file.
parse_fullchains() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*ssl_certificate\s+(.*);.*&\1&p' | xargs -n1 echo | uniq
}

# Return all unique "ssl_trusted_certificate" file paths.
#
# $1: Path to a Nginx configuration file.
parse_chains() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*ssl_trusted_certificate\s+(.*);.*&\1&p' | xargs -n1 echo | uniq
}

# Return all unique "dhparam" file paths.
#
# $1: Path to a Nginx configuration file.
parse_dhparams() {
    nginx_config_stream "$1" | sed -n -r -e 's&^\s*ssl_dhparam\s+(.*);.*&\1&p' | xargs -n1 echo | uniq
}

# Given a config file path, return 0 if all SSL related files exist (or there
# are no files needed to be found). Return 1 otherwise (i.e. error exit code).
#
# This function calls the following functions in the specified order:
#  - parse_keyfiles
#  - parse_fullchains
#  - parse_chains
#  - parse_dhparams
#
# $1: Path to a Nginx configuration file.
allfiles_exist() {
    local all_exist=0
    for type in keyfile fullchain chain dhparam; do
        for path in $(parse_"${type}"s "$1"); do
            if [[ "${path}" == data:* ]]; then
                debug "Ignoring ${type} path starting with 'data:' in '${1}'"
            elif [[ "${path}" == engine:* ]]; then
                debug "Ignoring ${type} path starting with 'engine:' in '${1}'"
            elif [ ! -s "${path}" ]; then
                warning "Could not find non-zero size ${type} file '${path}' in '${1}'"
                all_exist=1
            fi
        done
    done

    return ${all_exist}
}

# Parse the configuration file to find all the 'ssl_certificate_key' and the
# 'server_name' entries, and aggregate the findings so a single certificate can
# be ordered for multiple domains if this is desired. Each keyfile must be
# stored in /etc/letsencrypt/live/<cert_name>/privkey.pem, otherwise the
# certificate/file will be ignored.
#
# If you are using the same associative array between each call to this function
# it will make sure that only unique domain names are added to each specific
# key. It will also ignore domain names that start with '~', since these are
# regex and we cannot handle those.
#
# $1: The filepath to the configuration file.
# $2: An associative bash array that will contain cert_name => server_names
#     (space-separated) after the call to this function.
parse_config_file() {
    local conf_file=${1}
    local -n certs=${2} # Basically a pointer to the array sent in via $2.
    debug "Parsing config file '${conf_file}'"

    # Begin by checking if there are any certificates managed by us in the
    # config file.
    local cert_names=()
    for cert_name in $(parse_cert_names "${conf_file}"); do
        cert_names+=("${cert_name}")
    done
    if [ ${#cert_names[@]} -eq 0 ]; then
        debug "Found no valid certificate declarations in '${conf_file}'; skipping it"
        return
    fi

    # Then we look for all the possible server names present in the file.
    local server_names=()
    local replacement_domain=""
    for server_name in $(parse_server_names "${conf_file}"); do
        # Check if the current server_name line has a comment that tells us to
        # use a different domain name instead when making the request.
        # Both "lego_domain:" and "certbot_domain:" (legacy) are supported.
        if [[ "${server_name}" =~ (lego_domain|certbot_domain):(.*) ]]; then
            local _domain_prefix="${BASH_REMATCH[1]}"
            if [ "${server_name}" == "${_domain_prefix}:${replacement_domain}" ]; then
                # We found the end of the special server names.
                replacement_domain=""
                continue
            fi
            replacement_domain="${BASH_REMATCH[2]}"
            server_names+=("${replacement_domain}")
            continue
        fi
        if [ -n "${replacement_domain}" ]; then
            # Just continue in case we are substituting domains.
            debug "Substituting '${server_name}' with '${replacement_domain}'"
            continue
        fi

        # Ignore regex names, since these are not gracefully handled by this
        # code or lego.
        if [[ "${server_name}" =~ ~(.*) ]]; then
            debug "Ignoring server name '${server_name}' since it looks like a regex and we cannot handle that"
            continue
        fi

        # Ignore nginx variables since these cannot be gracefully handled
        if [[ "${server_name}" =~ \$(.+) ]]; then
            debug "Ignoring server name '${server_name}' since it looks like an nginx variable and we cannot handle that"
            continue
        fi

        server_names+=("${server_name}")
    done
    debug "Found the following domain names: ${server_names[*]}"

    # Finally we add the found server names to the certificate names in
    # the associative array.
    for cert_name in "${cert_names[@]}"; do
        if ! [ ${certs["${cert_name}"]+_} ]; then
            debug "Adding new key '${cert_name}' in array"
            certs["${cert_name}"]=""
        else
            debug "Appending to already existing key '${cert_name}'"
        fi
        # Make sure we only add unique entries every time.
        # This invocation of awk works like 'sort -u', but preserves order. This
        # set the first 'server_name' entry as the first '-d' domain artgument
        # for the lego command. This domain will be your Common Name on the
        # certificate.
        # stackoverflow on this awk usage: https://stackoverflow.com/a/45808487
        certs["${cert_name}"]="$(echo "${certs["${cert_name}"]}" "${server_names[@]}" | xargs -n1 echo | awk '!a[$0]++' | tr '\n' ' ')"
    done
}

# FORK: this function does not exist upstream. Do not overwrite this file from
# upstream wholesale; see UPSTREAM_SYNC.md.
#
# Add certificates that no Nginx server block references.
#
# Discovery is driven by the Nginx configuration, which is correct for every
# certificate Nginx itself serves. It cannot see a certificate this container
# obtains on behalf of something else — a separate TLS terminator sitting in
# front of Nginx, or a service that reads the PEM files directly. Without a way
# to declare those, the only available trick was to add a dummy server block
# purely so discovery would trip over it: obscure, undocumented, and one tidy-up
# away from silently ending renewal.
#
# Format — entries separated by ';', domains within an entry by ',':
#   LEGO_EXTRA_CERTS="<cert_name>=<domain>[,<domain>...][;<cert_name>=...]"
#
# Example:
#   LEGO_EXTRA_CERTS="edge=example.com,www.example.com;api=*.api.example.com"
#
# A cert_name follows exactly the same rules as one parsed out of a config file:
# it becomes /etc/letsencrypt/live/<cert_name>/ and may carry a dns-<provider>
# suffix to select credentials. An entry naming a certificate that was already
# discovered from the Nginx config is merged into it, never duplicated, so
# declaring one redundantly is harmless.
#
# A malformed entry is reported and skipped rather than fatal: one typo must not
# stop every other certificate in the list from renewing.
#
# $1: An associative bash array that will contain cert_name => server_names
#     (space-separated) after the call to this function.
parse_extra_certs() {
    local -n certs=${1}

    if [ -z "${LEGO_EXTRA_CERTS:-}" ]; then
        return 0
    fi

    local entries=() domains=() server_names=()
    local entry cert_name domain_list domain raw

    # 'read' stops at the first newline, so a value written across several lines
    # would have everything after line one silently discarded — the worst
    # possible failure for this feature, since a certificate that is never
    # requested is only noticed when it expires. Fold newlines into spaces (and
    # drop carriage returns, for values coming from a CRLF env file) so the
    # multi-line form documented in advanced_usage.md genuinely works.
    raw="${LEGO_EXTRA_CERTS//$'\r'/}"
    raw="${raw//$'\n'/ }"

    IFS=';' read -r -a entries <<< "${raw}"

    for entry in "${entries[@]}"; do
        # Trim surrounding whitespace, so the value may be written across
        # multiple lines for readability.
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        if [ -z "${entry}" ]; then
            continue
        fi

        if [[ "${entry}" != *=* ]]; then
            error "Ignoring LEGO_EXTRA_CERTS entry '${entry}': expected <cert_name>=<domains>"
            continue
        fi

        cert_name="${entry%%=*}"
        domain_list="${entry#*=}"
        cert_name="${cert_name//[[:space:]]/}"

        if [ -z "${cert_name}" ] || [ -z "${domain_list}" ]; then
            error "Ignoring LEGO_EXTRA_CERTS entry '${entry}': empty certificate name or domain list"
            continue
        fi

        # The name becomes a path component under /etc/letsencrypt/live/, so
        # keep it to characters that cannot climb out of that directory. A name
        # parsed from an Nginx config is not checked this way, but there the
        # operator at least sees the full path they typed; here they see only a
        # short name and would not expect it to be path-significant.
        # Must begin with an alphanumeric, '_' or '-', which also rules out the
        # names '.' and '..' that the character class alone would allow.
        if ! [[ "${cert_name}" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]]; then
            error "Ignoring LEGO_EXTRA_CERTS entry '${entry}': certificate name may only contain letters, digits, '.', '_' and '-', and may not begin with '.'"
            continue
        fi

        server_names=()
        IFS=',' read -r -a domains <<< "${domain_list}"
        for domain in "${domains[@]}"; do
            domain="${domain//[[:space:]]/}"
            if [ -z "${domain}" ]; then
                continue
            fi
            # Each domain must look like a host name, optionally a wildcard.
            # This is what catches an entry accidentally welded onto its
            # neighbour by a missing ';' at the end of a line — without it the
            # two fuse into one nonsense domain and take a working certificate
            # down with them.
            if ! [[ "${domain}" =~ ^\*?[A-Za-z0-9._-]+$ ]]; then
                error "Ignoring domain '${domain}' in LEGO_EXTRA_CERTS entry '${entry}': not a valid host name"
                continue
            fi
            server_names+=("${domain}")
        done

        if [ ${#server_names[@]} -eq 0 ]; then
            error "Ignoring LEGO_EXTRA_CERTS entry '${entry}': no usable domain names"
            continue
        fi

        debug "Adding extra certificate '${cert_name}' for: ${server_names[*]}"

        if ! [ ${certs["${cert_name}"]+_} ]; then
            certs["${cert_name}"]=""
        else
            debug "Merging extra domains into already discovered '${cert_name}'"
        fi

        # Order-preserving merge that drops duplicates. Deliberately a plain
        # bash loop rather than parse_config_file's 'echo | xargs | awk | tr':
        # xargs interprets quotes and backslashes, so a stray quote there
        # discards the whole list and a backslash silently rewrites a domain.
        local existing merged=() known=" "
        for existing in ${certs["${cert_name}"]}; do
            case "${known}" in *" ${existing} "*) continue ;; esac
            merged+=("${existing}")
            known="${known}${existing} "
        done
        for domain in "${server_names[@]}"; do
            case "${known}" in *" ${domain} "*) continue ;; esac
            merged+=("${domain}")
            known="${known}${domain} "
        done
        certs["${cert_name}"]="${merged[*]} "
    done
}

# Creates symlinks from /etc/nginx/conf.d/ to all the files found inside
# /etc/nginx/user_conf.d/. This will also remove broken links.
symlink_user_configs() {
    debug "Creating symlinks to any files found in /etc/nginx/user_conf.d/"

    # Remove any broken symlinks that point back to the user_conf.d/ folder.
    while IFS= read -r -d $'\0' symlink; do
        info "Removing broken symlink '${symlink}' to '$(realpath "${symlink}")'"
        rm "${symlink}"
    done < <(find /etc/nginx/conf.d/ -xtype l -lname '/etc/nginx/user_conf.d/*' -print0)

    # Go through all files and directories in the user_conf.d/ folder and create
    # a symlink to them inside the conf.d/ folder.
    while IFS= read -r -d $'\0' source_file; do
        local symlinks_found=0

        # See if there already exist a symlink to this source file.
        while IFS= read -r -d $'\0' symlink; do
            debug "The file '${source_file}' is already symlinked by '${symlink}'"
            symlinks_found=$((symlinks_found + 1))
        done < <(find -L /etc/nginx/conf.d/ -samefile "${source_file}" -print0)

        if [ "${symlinks_found}" -eq "1" ]; then
            # One symlink found, then we have nothing more to do.
            continue
        elif [ "${symlinks_found}" -gt "1" ]; then
            warning "Found more than one symlink to the file '${source_file}' inside '/etc/nginx/conf.d/'"
            continue
        fi

        # No symlinks to this file found, lets create one by just trimming the
        # known base folder path from the file and replacing it with our new
        # base file path.
        local link
        link="/etc/nginx/conf.d/${source_file#'/etc/nginx/user_conf.d/'}"
        info "Creating symlink '${link}' to '${source_file}'"
        mkdir_log "$(dirname -- "${link}")"
        ln -s "${source_file}" "${link}"
    done < <(find /etc/nginx/user_conf.d/ -type f -print0)
}

# Helper function that sifts through /etc/nginx/conf.d/, looking for configs
# that don't have their necessary files yet, and disables them until everything
# has been set up correctly. This also activates them afterwards.
auto_enable_configs() {
    while IFS= read -r -d $'\0' conf_file; do
        if allfiles_exist "${conf_file}"; then
            if [ "${conf_file##*.}" = "nokey" ]; then
                info "Found all the necessary files for '${conf_file}', enabling..."
                mv "${conf_file}" "${conf_file%.*}"
            fi
        else
            if [ "${conf_file##*.}" = "conf" ]; then
                error "Important file(s) for '${conf_file}' are missing or empty, disabling..."
                mv "${conf_file}" "${conf_file}.nokey"
            fi
        fi
    done < <(find -L /etc/nginx/conf.d/ -name "*.conf*" -type f -print0)
}

# FORK: this function does not exist upstream. Do not overwrite this file from
# upstream wholesale; see UPSTREAM_SYNC.md.
#
# Give the group named in NGINX_LEGO_CERT_GROUP read access to the certificates,
# so another container (a TLS terminator in front of this one, say) can use them
# without running as this container's user or as root.
#
# lego writes every key 0600 inside 0700 directories. This opens exactly the way
# to the certificate files: certificates/, live/ and each live/<name>/ become
# 0750, and the certificates and keys 0640, all owned by that group. The local CA
# writes real files into live/<name>/, so those are shared as well; lego only
# leaves symlinks there. The ACME account key (accounts/), lego's metadata
# (*.json), DNS credentials (*.ini), archive/ and dhparams/ are never touched, and
# no symlink is ever followed, so nothing outside these directories can change.
#
# Unset or empty leaves every permission as lego wrote it. A group this process
# does not belong to cannot be handed out, so that is reported with the fix and
# the files stay private.
#
# $1: Root of the certificate store (default: LEGO_PATH, or /etc/letsencrypt).
share_certificates() {
    local group="${NGINX_LEGO_CERT_GROUP:-}"
    local root="${1:-${LEGO_PATH:-/etc/letsencrypt}}"
    if [ -z "${group}" ]; then
        return 0
    fi

    # Each find tolerates a missing directory: the process substitution inherits
    # 'set -e' from callers such as run_local_ca.sh, so one failing find (the
    # local CA has no certificates/) would otherwise silently skip the rest.
    local -a paths=()
    local path
    while IFS= read -r -d $'\0' path; do
        paths+=("${path}")
    done < <(
        find -P "${root}/certificates" -maxdepth 0 -type d -print0 2>/dev/null || true
        find -P "${root}/live" -maxdepth 1 -type d -print0 2>/dev/null || true
        find -P "${root}/certificates" -maxdepth 1 -type f \( -name '*.crt' -o -name '*.key' \) -print0 2>/dev/null || true
        find -P "${root}/live" -mindepth 2 -maxdepth 2 -type f -name '*.pem' -print0 2>/dev/null || true
    )
    if [ ${#paths[@]} -eq 0 ]; then
        debug "No certificates in '${root}' to share with group '${group}' yet"
        return 0
    fi

    local mode out refused=""
    for path in "${paths[@]}"; do
        if [ -d "${path}" ]; then mode=750; else mode=640; fi
        # Only widen the mode once the group is right, or a refused chgrp would
        # leave the key readable by whatever group it already had.
        if ! out="$(chgrp "${group}" "${path}" 2>&1)"; then
            refused="${out}"
            continue
        fi
        chmod "${mode}" "${path}"
        debug "Shared '${path}' with group '${group}' (${mode})"
    done

    if [ -n "${refused}" ]; then
        error "Could not give the certificates in '${root}' to group '${group}': ${refused}"
        error "This container runs as uid $(id -u) with groups '$(id -G)' and can only hand files to one of them. Add the group to the container (docker run --group-add ${group}, compose 'group_add', Kubernetes 'supplementalGroups'), or set NGINX_LEGO_CERT_GROUP to a group it already has."
        return 1
    fi
    info "Certificates in '${root}' are readable by group '${group}'"
}

# FORK: this function does not exist upstream. Do not overwrite this file from
# upstream wholesale; see UPSTREAM_SYNC.md.
#
# Make sure this container's user can write everything it will have to write in
# the certificate store, and say exactly how to fix it when it cannot.
#
# The image used to run as root, so a volume carried over from those days belongs
# to root. Every renewal would then fail with a bare "permission denied", and
# Nginx could not even read the keys. Checking once, before anything else runs,
# turns that into one clear message with the command that fixes it.
#
# Credential files are not checked: they are often mounted read-only and only
# have to be readable, which load_credentials reports on its own. Symlinks are
# skipped, since a dangling one is not a permission problem.
#
# $1: Root of the certificate store (default: LEGO_PATH, or /etc/letsencrypt).
check_storage_writable() {
    local root="${1:-${LEGO_PATH:-/etc/letsencrypt}}"
    local -a trees=()
    local sub
    for sub in accounts certificates live archive dhparams; do
        if [ -e "${root}/${sub}" ]; then
            trees+=("${root}/${sub}")
        fi
    done
    if [ 1 = "${USE_LOCAL_CA}" ] && [ -e "${LOCAL_CA_DIR:-/etc/local_ca}" ]; then
        trees+=("${LOCAL_CA_DIR:-/etc/local_ca}")
    fi

    # The shell's own -w test rather than find's -writable, which busybox find
    # lacks: an unsupported option there would make this check pass silently.
    local denied="" path
    if [ ! -w "${root}" ]; then
        denied="${root}"
    elif [ ${#trees[@]} -gt 0 ]; then
        while IFS= read -r -d $'\0' path; do
            if [ ! -L "${path}" ] && [ ! -w "${path}" ]; then
                denied="${path}"
                break
            fi
        done < <(find "${trees[@]}" -print0 2>/dev/null || true)
    fi
    if [ -z "${denied}" ]; then
        return 0
    fi

    local owner
    owner="$(id -u):$(id -g)"
    error "This container runs as uid $(id -u) and cannot write '${denied}'."
    error "The image no longer runs as root, so files written by an older, root-run container must be handed over once. Run, then start again:"
    error "  docker run --rm --user 0 -v <your volume or host directory>:${root} <this image> chown -R ${owner} ${root}"
    error "or on the host: sudo chown -R ${owner} <host directory>"
    return 1
}
