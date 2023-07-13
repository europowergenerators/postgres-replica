#!/usr/bin/env bash
set -euo pipefail

COPY_PGPASSWORD="${PGPASSWORD:-}"
POSTGRES_REPLICATION_SLOT="${POSTGRES_REPLICATION_SLOT:-replication_slot_ep}"
POSTGRES_REPLICATION_USER="${POSTGRES_REPLICATION_USER:-replication_ep_onsite}"

docker_temp_server_start() {
	PGUSER="${PGUSER:-$POSTGRES_USER}" \
    PGPASSWORD="${COPY_PGPASSWORD}" \
	pg_ctl -D "$PGDATA" -w start
    unset PGPASSWORD
}

# stop postgresql server after done setting up user and running scripts
docker_temp_server_stop() {
	PGUSER="${PGUSER:-postgres}" \
    PGPASSWORD="${COPY_PGPASSWORD}" \
	pg_ctl -D "$PGDATA" -m fast -w stop
    unset PGPASSWORD
}

echo "Script running as: $(whoami)"

# ERROR; This script is called with PGPASSWORD set!
# PGPASSWORD has higher priority, so it needs to be unset for this script and PGPASSFILE will take effect
unset PGPASSWORD
export PGPASSFILE=/config/.pgpass

# WARN; head doesn't consume the full pipe, which is as intended. Not consuming the full pipe produces
# a pipefail returncode, so we have to disable pipefail propagation every time using head
set +o pipefail
if [ -s "${PGPASSFILE}" ]
then
    # File exists and is not empty
    POSTGRES_REPLICATION_USER=$(cat "${PGPASSFILE}" | head -n 1 | cut -d ':' -f 4)
    POSTGRES_REPLICATION_PASSWORD=$(cat "${PGPASSFILE}" | head -n 1 | cut -d ':' -f 5)
else
    POSTGRES_REPLICATION_PASSWORD=$(cat /dev/random | tr -dc '[:alnum:]' | head -c 20)
    echo "*:*:*:${POSTGRES_REPLICATION_USER}:${POSTGRES_REPLICATION_PASSWORD}" > "${PGPASSFILE}"
    chmod 0600 "${PGPASSFILE}"    
fi
# NOTE; Re-enable pipefail propagation, see note above
set -o pipefail

if [ -z "${REPLICATE_FROM_HOST:-}" ]
then
    echo "You must set environment variable 'REPLICATE_FROM_HOST' for this container to work!"
    exit 1
fi

pg_isready -t 1 -h "${REPLICATE_FROM_HOST}"
if [ $? -ne 0 ]
then
    echo "Waiting for master to respond..."    
    until pg_isready -t 1 -h "${REPLICATE_FROM_HOST}"
    do
        sleep 1s
    done
fi

echo
echo "========== Master setup =========="
echo "The master database requires some setup before replication can happen!"
echo "1. Create replication role (user)"
echo -e "\$\tpsql -v ON_ERROR_STOP=1 -d postgres --single-line <<-EOSQL"
echo -e "\tcreate role ${POSTGRES_REPLICATION_USER} with REPLICATION LOGIN password '${POSTGRES_REPLICATION_PASSWORD}';"
echo -e "EOSQL"

echo "2. Create a transaction tracker for our replica on the master"
echo -e "\$\tpsql -v ON_ERROR_STOP=1 -d postgres --single-line <<-EOSQL"
echo -e "\tSELECT * FROM pg_create_physical_replication_slot('${POSTGRES_REPLICATION_SLOT}');"
echo -e "EOSQL"

echo "3. Allow access to the master, through the replication account"
echo -e "\$\tcp \"\${PGDATA}/pg_hba.conf\" \"\${PGDATA}/pg_hba.conf.backup\""
echo -e "\$\techo \"host    replication    ${POSTGRES_REPLICATION_USER}    127.0.0.0/24    md5\" | tee -a \"\${PGDATA}/pg_hba.conf\""

echo "4. Update master configuration to allow replication"
echo -e "\$\tcat >> \"\${PGDATA}/conf.d/replication_ep_onsite.conf\" <<-EOCONF"
echo -e "\twal_level = replica"
echo -e "\tarchive_mode = off"
echo -e "\tmax_wal_senders = 3"
echo -e "\tmax_replication_slots = 3"
echo -e "EOCONF"

echo "5. Restart the server (wal_level change requires server restart)"
echo -e "\$\systemctl restart postgresql"

echo "6. Setup replication slot cleanup if the slave goes offline for too long"
echo -e "\$\tpsql -v ON_ERROR_STOP -d postgres --single-line <<-EOSQL"
echo -e "\tselect pg_drop_replication_slot(slot_name) from pg_replication_slots where slot_name = '${POSTGRES_REPLICATION_SLOT}' and active = 'f';"
echo -e "EOSQL"

echo "========== Master setup =========="
echo

docker_temp_server_stop
# WARN; There is a possibility pg_hba.conf gets removed, so duplicate it to restore later
cp "${PGDATA}/pg_hba.conf" "/tmp/pg_hba.conf"

# NOTE; pg_basebackup will copy over _all master configuration_ and write out the replication configuration
rm -rf ${PGDATA}/*
until pg_basebackup --write-recovery-conf -X stream --checkpoint=fast --slot="${POSTGRES_REPLICATION_SLOT}" \
        -h "${REPLICATE_FROM_HOST}" -D "${PGDATA}" -U "${POSTGRES_REPLICATION_USER}" -w  -vP
do
    echo "Waiting for master to connect..."
    sleep 5s
done

# Notify current server as standby
touch "${PGDATA}/standby.signal"
# Store additional configuration outside of the postgresql
mkdir -p "${PGDATA}/conf.d"

cat >> "${PGDATA}/postgresql.conf" <<EOCONF
# Include more configuration
include_dir = '${PGDATA}/conf.d'
EOCONF

cat >> "${PGDATA}/conf.d/replica.conf" <<EOCONF
# Hot standby allows querying this server
hot_standby = on
# Allow external connections
listen_addresses = '*'


# Allow replication delay to complete running+conflicting transactions.
# This lowers the error rate with description '40001: canceling statement due to conflict with recovery.'
max_standby_archive_delay = 900s
max_standby_streaming_delay = 900s
EOCONF

# WARN; If $PGDATA and ~(homedir) overlap, we might have removed our pgpass file around pg_basebackup
if [ ! -f "${PGPASSFILE}" ]
then
    echo "*:*:*:${POSTGRES_REPLICATION_USER}:${POSTGRES_REPLICATION_PASSWORD}" > "${PGPASSFILE}"
    chmod 0600 "${PGPASSFILE}"
fi

# WORKAROUND; Depending on the master server, pg_*.conf files get removed during pg_basebackup
if [ ! -f "${PGDATA}/pg_hba.conf" ]
then
    cp "/tmp/pg_hba.conf" "${PGDATA}/pg_hba.conf"
fi

if [ ! -f "${PGDATA}/pg_ident.conf" ]
then
    # NOTE; No content required
    touch "${PGDATA}/pg_ident.conf"
fi

docker_temp_server_start