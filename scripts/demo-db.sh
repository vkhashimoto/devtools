#!/usr/bin/env bash
# Throwaway Postgres for trying devtools (run inside `nix develop`).
# Usage: scripts/demo-db.sh start|stop
set -euo pipefail
root="${DEVTOOLS_DEMO_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/devtools-demo}"
port=54329
export PGPASSWORD=devpass

case "${1:-}" in
  start)
    if [ ! -d "$root/pgdata" ]; then
      mkdir -p "$root"
      echo "$PGPASSWORD" > "$root/pw"
      initdb -D "$root/pgdata" -U dev --pwfile="$root/pw" --auth=scram-sha-256 >/dev/null
      rm "$root/pw"
    fi
    pg_ctl -D "$root/pgdata" status >/dev/null ||
      pg_ctl -D "$root/pgdata" -l "$root/postgres.log" -o "-p $port -k $root -h localhost" -w start
    psql -h localhost -p $port -U dev -d postgres -q -v ON_ERROR_STOP=1 <<'SQL'
SELECT 'CREATE DATABASE app' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'app')\gexec
SQL
    psql -h localhost -p $port -U dev -d app -q -v ON_ERROR_STOP=1 <<'SQL'
SET client_min_messages = warning;
CREATE TABLE IF NOT EXISTS orders (
  id serial PRIMARY KEY,
  customer text NOT NULL,
  total numeric(10,2) NOT NULL,
  status text NOT NULL,
  created_at timestamptz DEFAULT now()
);
INSERT INTO orders (customer, total, status)
SELECT * FROM (VALUES ('acme', 120.50, 'open'),
                      ('globex', 89.90, 'shipped'),
                      ('initech', 42.00, 'open')) v
WHERE NOT EXISTS (SELECT FROM orders);
SQL
    echo "Demo database ready: postgres://dev:devpass@localhost:$port/app"
    ;;
  stop)
    pg_ctl -D "$root/pgdata" -w stop
    ;;
  *)
    echo "usage: $0 start|stop" >&2
    exit 1
    ;;
esac
