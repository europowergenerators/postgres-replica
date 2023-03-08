#!/usr/bin/env bash
set -euo pipefail

REPLICATE_FROM=master
REPLICATION_SLOT=repl_slot

echo "Script running as: $(whoami)"
# WARN; _ALL master configuration_ is later streamed to the slaves!

psql -v ON_ERROR_STOP=1 -d postgres --single-line <<-EOSQL
create role ${POSTGRES_REPLICATION_USER} with REPLICATION LOGIN password '${POSTGRES_REPLICATION_PASSWORD}';
EOSQL

psql -v ON_ERROR_STOP=1 -d postgres --single-line <<-EOSQL
SELECT * FROM pg_create_physical_replication_slot('${REPLICATION_SLOT}');
EOSQL

cp "${PGDATA}/pg_hba.conf" "${PGDATA}/pg_hba.conf.backup"
echo "host    replication    ${POSTGRES_REPLICATION_USER}    0.0.0.0/0    md5" | tee -a "${PGDATA}/pg_hba.conf"

cp "${PGDATA}/postgresql.conf" "${PGDATA}/postgresql.conf.backup"
cat >> "${PGDATA}/postgresql.conf" <<EOF
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
EOF

pg_ctl reload -s -D "${PGDATA}"