#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$ROOT_DIR/.env" ]]; then
  echo "Missing $ROOT_DIR/.env. Copy .env.example and configure it first." >&2
  exit 1
fi

set -a
# shellcheck disable=SC1091
source "$ROOT_DIR/.env"
set +a

# WSL can route 127.0.0.1 through loopback0 while Java creates an IPv4-mapped
# IPv6 listener. A real IPv4 socket remains reachable from both WSL and Windows.
if grep -qi microsoft /proc/sys/kernel/osrelease \
  && [[ " ${JAVA_TOOL_OPTIONS:-} " != *" -Djava.net.preferIPv4Stack="* ]]; then
  export JAVA_TOOL_OPTIONS="${JAVA_TOOL_OPTIONS:+$JAVA_TOOL_OPTIONS }-Djava.net.preferIPv4Stack=true"
fi

cd "$ROOT_DIR/server"
exec ./mvnw spring-boot:run
