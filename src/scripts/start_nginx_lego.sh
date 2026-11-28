#!/bin/bash

# Helper function to gracefully shut down our child processes when we exit.
clean_exit() {
    for PID in "${NGINX_PID}" "${LEGO_LOOP_PID}"; do
        if kill -0 "${PID}" 2>/dev/null; then
            kill -SIGTERM "${PID}"
            wait "${PID}"
        fi
    done
}

# Make bash listen to the SIGTERM, SIGINT and SIGQUIT kill signals, and make
# them trigger a normal "exit" command in this script. Then we tell bash to
# execute the "clean_exit" function, seen above, in the case an "exit" command
# is triggered. This is done to give the child processes a chance to exit
# gracefully.
trap "exit" TERM INT QUIT
trap "clean_exit" EXIT

# Source "util.sh" so we can have our nice tools.
. "$(cd "$(dirname "$0")"; pwd)/util.sh"

# If the environment variable `DEBUG=1` is set, then this message is printed.
debug "Debug messages are enabled"

# FORK: not present upstream. Do not drop when syncing this file; see
# UPSTREAM_SYNC.md.
#
# NGINX_LEGO_ROLE (util.sh): 'all', the default, does everything below. An
# 'issuer' runs lego and keeps the store but starts no Nginx; a 'server' starts
# Nginx only, from a store an issuer keeps, and must be cut off from it.
role="$(nginx_lego_role)" || exit 1
case "${role}" in
    issuer) check_issuer_ready || exit 1 ;;
    server) check_server_isolation || exit 1 ;;
esac
if [ "${role}" != "all" ]; then
    info "Running as the ${role} of a split setup (NGINX_LEGO_ROLE=${role})"
fi

# FORK: not present upstream. Do not drop when syncing this file; see
# UPSTREAM_SYNC.md.
#
# The image runs as an unprivileged user. Stop here, with the command that fixes
# it, when the certificate storage still belongs to someone else (root, from an
# older image), rather than failing every renewal later. A server only reads
# the store, so it is not checked there.
if [ "${role}" != "server" ] && ! check_storage_writable; then
    exit 1
fi

# FORK: a server may have conf.d on a tmpfs; put the image's own files back.
if [ "${role}" = "server" ]; then
    restore_image_conf
fi

# Immediately symlink files to the correct locations and then run
# 'auto_enable_configs' so that Nginx is in a runnable state
# This will temporarily disable any misconfigured servers. An issuer only needs
# the configs to know which certificates to get.
symlink_user_configs
if [ "${role}" != "issuer" ]; then
    auto_enable_configs
fi

# FORK: not present upstream. Do not drop when syncing this file; see
# UPSTREAM_SYNC.md.
#
# Certificates issued before NGINX_LEGO_CERT_GROUP was set get the group now,
# not only at their next renewal.
if [ "${role}" != "server" ]; then
    share_certificates || true
fi

# Start Nginx without its daemon mode (and save its PID).
if [ "${role}" = "issuer" ]; then
    debug "An issuer starts no Nginx"
elif [ 1 = "${DEBUG}" ]; then
    info "Starting the Nginx service in debug mode"
    nginx-debug -g "daemon off;" &
    NGINX_PID=$!
else
    info "Starting the Nginx service"
    nginx -g "daemon off;" &
    NGINX_PID=$!
fi
debug "PID of the main Nginx process: ${NGINX_PID}"

# Make sure a renewal interval is set before continuing.
if [ -z "${RENEWAL_INTERVAL}" ]; then
    debug "RENEWAL_INTERVAL unset, using default of '8d'"
    RENEWAL_INTERVAL='8d'
fi
loop_sleep="${RENEWAL_INTERVAL}"

if [ "${role}" = "server" ]; then
# FORK: not present upstream. Do not drop when syncing this file; see
# UPSTREAM_SYNC.md.
#
# A server renews nothing. It looks at the issuer's mark every
# NGINX_LEGO_RELOAD_CHECK seconds and reloads Nginx once per renewal, as long
# as it is still cut off from the issuer. The last mark seen is kept in /run,
# which Nginx needs writable anyway.
loop_sleep="${NGINX_LEGO_RELOAD_CHECK:-60}"
(
set -e
seen=/run/nginx-lego-renewal-seen
store="${LEGO_PATH:-/etc/letsencrypt}"
if [ -f "${store}/.nginx-lego-renewed" ]; then
    cp "${store}/.nginx-lego-renewed" "${seen}"
else
    : > "${seen}"
fi
while true; do
    sleep "${loop_sleep}" || x=$?; if [ -n "${x}" ] && [ "${x}" -ne "143" ]; then exit "${x}"; fi
    if check_server_isolation "${store}"; then
        server_watch_once "${store}" "${seen}"
    else
        error "Not reloading Nginx: this server is no longer cut off from the issuer"
    fi
done
) &
LEGO_LOOP_PID=$!
debug "PID of the reload watch loop: ${LEGO_LOOP_PID}"
else
# Instead of trying to run 'cron' or something like that, just sleep and
# call on lego after the defined interval.
(
set -e
while true; do
    info "Running the autorenewal service"

    # Create symlinks from conf.d/ to user_conf.d/ if necessary.
    symlink_user_configs

    # Check that all dhparam files exists.
    "$(cd "$(dirname "$0")"; pwd)/create_dhparams.sh"

    if [ 1 = "${USE_LOCAL_CA}" ]; then
        # Renew all certificates with the help of the local CA.
        "$(cd "$(dirname "$0")"; pwd)/run_local_ca.sh"
    else
        # FORK: certbot removed; lego handles all certificate types.
        "$(cd "$(dirname "$0")"; pwd)/run_lego.sh"
    fi

    # Finally we sleep for the defined time interval before checking the
    # certificates again.
    # The "if" statement afterwards is to enable us to terminate this sleep
    # process (via the HUP trap) without tripping the "set -e" setting.
    info "Autorenewal service will now sleep ${RENEWAL_INTERVAL}"
    sleep "${RENEWAL_INTERVAL}" || x=$?; if [ -n "${x}" ] && [ "${x}" -ne "143" ]; then exit "${x}"; fi
done
) &
LEGO_LOOP_PID=$!
debug "PID of the autorenewal loop: ${LEGO_LOOP_PID}"
fi

# A helper function to prematurely terminate the sleep process, inside the
# autorenewal loop process, in order to immediately restart the loop again
# and thus reload any configuration files.
reload_configs() {
    info "Received SIGHUP signal; terminating the autorenewal sleep process"
    if ! pkill -15 -P "${LEGO_LOOP_PID}" -fx "sleep ${loop_sleep}"; then
        warning "No sleep process found, this most likely means that a renewal process is currently running"
    fi
    # On success we return 128 + SIGHUP in order to reduce the complexity of
    # the final wait loop.
    return 129
}

# Create a trap that listens to SIGHUP and runs the reloader function in case
# such a signal is received.
trap "reload_configs" HUP

# Signal handler for SIGUSR1: forward it to nginx to reopen log files
reopen_logs() {
    if [ -n "${NGINX_PID}" ]; then
        info "Received SIGUSR1 signal; telling nginx to reopen log files"
        nginx -s reopen
    fi
    return 138 # 128 + SIGUSR1
}
trap "reopen_logs" USR1

# Nginx and the lego renewal loop process are now our children. As a parent
# we will wait for both of their PIDs, and if one of them exits we will follow
# suit and use the same status code as the program which exited first.
# The loop is necessary since the signal traps will make any "wait" return
# immediately when triggered, and to not exit the entire program we will have
# to wait on the original PIDs again.
# An issuer has no Nginx to wait for.
children=("${LEGO_LOOP_PID}")
if [ -n "${NGINX_PID}" ]; then
    children+=("${NGINX_PID}")
fi
while [ -z "${exit_code}" ] || [ "${exit_code}" = "129" ] || [ "${exit_code}" = "138" ]; do
    wait -n "${children[@]}"
    exit_code=$?
done

debug "Exiting with code ${exit_code}"
exit "${exit_code}"
