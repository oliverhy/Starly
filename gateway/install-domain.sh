#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $# -lt 2 ]]; then
  echo "用法：sudo bash install-domain.sh <域名> <邮箱> [--staging]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd)"
exec bash "$SCRIPT_DIR/install.sh" --domain "$1" --email "$2" "${@:3}"
