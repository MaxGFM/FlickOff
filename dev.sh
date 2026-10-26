#!/usr/bin/env bash
set -euo pipefail

CONTAINER=aim-db

# Credentials come from .env (copy .env.example). No password default here.
if [[ ! -f .env ]]; then
  echo "error: .env not found. Copy .env.example to .env and set PGPASSWORD." >&2
  exit 1
fi
source .env
if [[ -z "${PGPASSWORD:-}" ]]; then
  echo "error: PGPASSWORD is not set in .env." >&2
  exit 1
fi
DB=${PGDATABASE:-aim}
USER=${PGUSER:-gameapp}
PASS=$PGPASSWORD

# If the container already exists, just start it; otherwise create it.
if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "DB already up"
elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  docker start "${CONTAINER}"
else
  docker run --name "$CONTAINER" \
    -e POSTGRES_USER=$USER \
    -e POSTGRES_PASSWORD=$PASS \
    -e POSTGRES_DB=$DB \
    -p 127.0.0.1:5432:5432 \
    -v $CONTAINER-data:/var/lib/postgresql/data \
    -d postgres:17
fi

echo "Waiting for Postgres..."
until docker exec "${CONTAINER}" pg_isready -U "$USER" >/dev/null 2>&1; do
  sleep 0.5
done
echo "Postgres ready on localhost:5432 (user: $USER, db: $DB)"

export DATABASE_URL="postgres://$USER:$PASS@localhost:5432/$DB?sslmode=disable"
export LISTEN_ADDR=":4000"
export WEB_DIR="../build/web"

cd server || exit 1
sleep 0.5
echo "Go server active"
go run ./cmd/api