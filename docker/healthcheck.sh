#!/usr/bin/env bash
set -Eeuo pipefail

mode=${WORDPRESS_HEALTHCHECK_MODE:-readiness}
case "${mode}" in
    liveness) endpoint=healthz-live.php; expected=live ;;
    readiness) endpoint=healthz.php; expected=ready ;;
    *)
        printf '[healthcheck] WORDPRESS_HEALTHCHECK_MODE deve essere liveness oppure readiness.\n' >&2
        exit 1
        ;;
esac

health_host=${WORDPRESS_DOMAIN:-localhost}
case "${health_host}" in
    http://*) health_host=${health_host#http://} ;;
    https://*) health_host=${health_host#https://} ;;
esac
health_host=${health_host%/}
[[ -n ${health_host} && ${health_host} != */* && ${health_host} != *[[:space:]]* ]] || {
    printf '[healthcheck] WORDPRESS_DOMAIN non è utilizzabile come header Host.\n' >&2
    exit 1
}

response=$(curl \
    --fail \
    --silent \
    --show-error \
    --max-time 4 \
    --header "Host: ${health_host}" \
    "http://127.0.0.1:7080/${endpoint}")

[[ ${response} == "${expected}" ]]
