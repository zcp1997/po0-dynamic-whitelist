#!/usr/bin/env bash
set -Eeuo pipefail
# Selective recovery only. Never restore a stale global firewall snapshot automatically.
exec "$(dirname "$0")/firewall.sh" repair
