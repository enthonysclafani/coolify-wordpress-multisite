#!/usr/bin/env bash
set -Eeuo pipefail

response=$(curl \
    --fail \
    --silent \
    --show-error \
    --max-time 4 \
    --header 'Host: localhost' \
    http://127.0.0.1:7080/healthz.php)

[[ ${response} == ok ]]
