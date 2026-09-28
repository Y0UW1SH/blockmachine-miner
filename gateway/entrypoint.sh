#!/bin/sh
set -e

# Default values if not set
: "${BACKEND_HOST:=127.0.0.1}"
: "${BACKEND_PORT:=9944}"
: "${BACKEND_HTTP_PORT:=}"
: "${BACKEND_WS_PORT:=}"
: "${SSL_CERT_PATH:=/etc/nginx/ssl/cert.pem}"
: "${SSL_KEY_PATH:=/etc/nginx/ssl/key.pem}"
: "${METRICS_HOST:=metrics}"
: "${METRICS_PORT:=9100}"
: "${SECRET_V1:=}"
: "${SECRET_V2:=}"

# The capacity helper is optional and lives outside this stack, usually on the
# host. Its address is written into proxy_pass literally, so nginx looks it up
# through /etc/hosts when it starts — which is where Docker puts the
# host.docker.internal entry from extra_hosts, and where nginx's own resolver
# would never look, because that resolver is Docker's DNS and Docker's DNS does
# not answer for that name.
#
# What a literal address cannot survive is a name that resolves to nothing:
# nginx then REFUSES TO START, which takes the whole gateway down, and all
# customer traffic with it, over a feature the operator may not even use. So a
# name that resolves to nothing is swapped for the loopback here. /capacity-test
# then answers 502, which costs a capacity test nothing — a node with no
# reachable helper is simply tested directly — and everything else carries on.
: "${CAPACITY_HELPER_HOST:=host.docker.internal}"
: "${CAPACITY_HELPER_PORT:=9955}"
if [ -z "$(getent hosts "$CAPACITY_HELPER_HOST" 2>/dev/null)" ]; then
    echo "WARNING: CAPACITY_HELPER_HOST '${CAPACITY_HELPER_HOST}' does not resolve."
    echo "         /capacity-test will answer 502 until it does. That costs a"
    echo "         capacity test nothing: the node is tested directly instead."
    echo "         Nothing else about this gateway is affected."
    CAPACITY_HELPER_HOST=127.0.0.1
fi
export CAPACITY_HELPER_HOST CAPACITY_HELPER_PORT

# The eth template picks the node's address through a variable, so that the
# Upgrade header can choose the HTTP or the WebSocket port. A variable makes
# nginx resolve the address per request, through the `resolver` directive —
# Docker's DNS — and Docker's DNS has never heard of host.docker.internal. That
# name exists only in this container's /etc/hosts, put there by extra_hosts.
#
# host.docker.internal is the default BACKEND_HOST, and the one install.sh
# offers, so an operator who takes the default gets 502 on every RPC request.
# A name that /etc/hosts defines is therefore turned into its address here,
# before nginx ever sees it.
#
# ONLY such a name. One served by real DNS is left exactly as it is, so nginx
# goes on re-resolving it and still follows the address if it moves.
backend_hosts_entry=$(awk -v name="$BACKEND_HOST" '
    /^[[:space:]]*#/ { next }
    $1 ~ /^[0-9]+(\.[0-9]+){3}$/ {
        for (i = 2; i <= NF; i++) if ($i == name) { print $1; exit }
    }
' /etc/hosts)
if [ -n "$backend_hosts_entry" ]; then
    BACKEND_HOST="$backend_hosts_entry"
fi
# Exported because envsubst reads the environment, not the shell: without this a
# BACKEND_HOST that only the default at the top set would render as an empty
# string.
export BACKEND_HOST

# Build the SECRET_V2 map line only if it differs from SECRET_V1
SECRET_V2_LINE=""
if [ -n "$SECRET_V2" ] && [ "$SECRET_V2" != "$SECRET_V1" ]; then
    SECRET_V2_LINE=$(printf '"Bearer %s" 1;' "$SECRET_V2")
fi
export SECRET_V2_LINE

# envsubst expects a shell-format string listing the variables to substitute.
# Single quotes are intentional — these are literal variable names, not expansions.
# The variable list is the union across all chain templates; vars unused by the
# active template (e.g. BACKEND_PORT for eth, BACKEND_HTTP_PORT for tao) are harmless.
# shellcheck disable=SC2016
envsubst '${SECRET_V1} ${SECRET_V2_LINE} ${SSL_CERT_PATH} ${SSL_KEY_PATH} ${BACKEND_HOST} ${BACKEND_PORT} ${BACKEND_HTTP_PORT} ${BACKEND_WS_PORT} ${METRICS_HOST} ${METRICS_PORT} ${CAPACITY_HELPER_HOST} ${CAPACITY_HELPER_PORT}' \
    < /etc/nginx/conf.d/miner-gateway.conf.template \
    > /etc/nginx/conf.d/default.conf

echo "Nginx configuration rendered"
if [ -n "$BACKEND_HTTP_PORT" ] || [ -n "$BACKEND_WS_PORT" ]; then
    echo "Backend HTTP: ${BACKEND_HOST}:${BACKEND_HTTP_PORT}"
    echo "Backend WS:   ${BACKEND_HOST}:${BACKEND_WS_PORT}"
else
    echo "Backend: ${BACKEND_HOST}:${BACKEND_PORT}"
fi
echo "Metrics: ${METRICS_HOST}:${METRICS_PORT}"
echo "Capacity helper: ${CAPACITY_HELPER_HOST}:${CAPACITY_HELPER_PORT}"
echo "SSL Cert: ${SSL_CERT_PATH}"
