#!/usr/bin/env bash
set -Eeuo pipefail
exec "$(dirname "$0")/firewall.sh" "${@:-install}"
