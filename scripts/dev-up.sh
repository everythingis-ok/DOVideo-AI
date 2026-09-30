#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

for command in docker curl java node ffmpeg tesseract; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env. Set SILICONFLOW_API_KEY and replace the example passwords, then run this script again."
  exit 1
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

for variable in \
  DB_PASSWORD MYSQL_ROOT_PASSWORD REDIS_PASSWORD MINIO_SECRET_KEY QDRANT_API_KEY SILICONFLOW_API_KEY; do
  value="${!variable:-}"
  if [[ -z "$value" || "$value" == change-* ]]; then
    echo "Set a non-example value for $variable in .env" >&2
    exit 1
  fi
done

if [[ "${DB_USERNAME:-}" != "${MYSQL_APP_USER:-dovideo}" ]]; then
  echo "DB_USERNAME and MYSQL_APP_USER must match." >&2
  exit 1
fi

java_version="$(java -version 2>&1 | awk -F '"' '/version/ { print $2; exit }')"
java_major="${java_version%%.*}"
[[ "$java_major" == "1" ]] && java_major="$(cut -d. -f2 <<<"$java_version")"
node_major="$(node --version | sed 's/^v//' | cut -d. -f1)"
(( java_major >= 21 )) || { echo "JDK 21+ is required; found $java_version" >&2; exit 1; }
(( node_major >= 22 )) || { echo "Node.js 22+ is required; found $(node --version)" >&2; exit 1; }

docker info >/dev/null
docker compose --env-file .env config --quiet
docker compose --env-file .env up --wait --wait-timeout 120

# The MySQL image only applies MYSQL_USER/MYSQL_PASSWORD while initializing an
# empty data directory. Keep the persisted application account aligned with
# the current .env without deleting the database.
mysql_container_id="$(docker compose --env-file .env ps -q mysql)"
if ! docker exec "$mysql_container_id" sh -eu -c '
  case "$MYSQL_USER" in
    ""|*[!A-Za-z0-9_]*)
      echo "MYSQL_APP_USER must contain only letters, digits, and underscores" >&2
      exit 1
      ;;
  esac

  password_hex="$(printf "%s" "$MYSQL_PASSWORD" | od -An -v -tx1 | tr -d " \n")"
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot --protocol=socket <<SQL
SET @new_password = CONVERT(0x${password_hex} USING utf8mb4);
SET @account = CONCAT(CHAR(39), "${MYSQL_USER}", CHAR(39), "@", CHAR(39), "%", CHAR(39));
SET @create_user = CONCAT(
  "CREATE USER IF NOT EXISTS ",
  @account,
  " IDENTIFIED BY ",
  QUOTE(@new_password)
);
PREPARE create_user_statement FROM @create_user;
EXECUTE create_user_statement;
DEALLOCATE PREPARE create_user_statement;
SET @alter_user = CONCAT(
  "ALTER USER ",
  @account,
  " IDENTIFIED BY ",
  QUOTE(@new_password)
);
PREPARE alter_user_statement FROM @alter_user;
EXECUTE alter_user_statement;
DEALLOCATE PREPARE alter_user_statement;
SET @grant_user = CONCAT("GRANT ALL PRIVILEGES ON media_db.* TO ", @account);
PREPARE grant_user_statement FROM @grant_user;
EXECUTE grant_user_statement;
DEALLOCATE PREPARE grant_user_statement;
FLUSH PRIVILEGES;
SQL
'; then
  echo "Unable to synchronize the MySQL application password." >&2
  echo "MYSQL_ROOT_PASSWORD is also initialization-only; restore its original value or reset it in MySQL." >&2
  exit 1
fi

curl --fail --silent --show-error --retry 20 --retry-connrefused --retry-delay 1 \
  --header "api-key: ${QDRANT_API_KEY}" \
  http://127.0.0.1:6333/healthz >/dev/null
curl --fail --silent --show-error --retry 20 --retry-connrefused --retry-delay 1 \
  http://127.0.0.1:9000/minio/health/live >/dev/null

docker compose --env-file .env ps
echo
echo "Infrastructure is ready. Start the backend with:"
echo "  ./scripts/dev-server.sh"
