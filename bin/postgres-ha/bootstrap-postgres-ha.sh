#!/bin/bash

# Copyright 2019 - 2020 Crunchy Data Solutions, Inc.
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

export PGHOST="/tmp"
export PGPORT="$PGHA_PG_PORT"

source /opt/cpm/bin/common/common_lib.sh
enable_debugging

trap_sigterm() {

    echo_warn "Signal trap triggered, beginning shutdown.." | tee -a "${PATRONI_POSTGRESQL_DATA_DIR}"/trap.output

    killall patroni
    echo_warn "Killed Patroni to gracefully shutdown PG" | tee -a "${PATRONI_POSTGRESQL_DATA_DIR}"/trap.output

    if [[ ${ENABLE_SSHD} == "true" ]]
    then
        echo_info "Killing SSHD.."
        killall sshd
    fi

    while killall -0 patroni; do
        echo_info "Waiting for Patroni to terminate.."
        sleep 1
    done
    echo_info "Patroni shutdown complete"
}

# Starts a background process to wait for cluster initialization, restart the database if configuration updates
# are needed, and indicate cluster readiness
initialization_monitor() {
    echo_info "Starting background process to monitor Patroni initization and restart the database if needed"
    {
        # Wait until the health endpoint for the local primary or replica to return 200 indicating it is running
        status_code=$(curl -o /dev/stderr -w "%{http_code}" "127.0.0.1:${PGHA_PATRONI_PORT}/health" 2> /dev/null)
        until [[ "${status_code}" == "200" ]]
        do
            sleep 1
            echo "Cluster not yet inititialized, retrying" >> "/tmp/patroni_initialize_check.log"
            status_code=$(curl -o /dev/stderr -w "%{http_code}" "127.0.0.1:${PGHA_PATRONI_PORT}/health" 2> /dev/null)
        done

        # Enable pgbackrest
        if [[ "${PGHA_PGBACKREST}" == "true" ]]
        then
            source "/opt/cpm/bin/pgbackrest/pgbackrest-post-bootstrap.sh"
        fi

        if [[ "${PGHA_INIT}" == "true" ]]
        then
            echo_info "PGHA_INIT is '${PGHA_INIT}', waiting to initialize as primary"
            # Wait until the master endpoint returns 200 indicating the local node is running as the current primary
            status_code=$(curl -o /dev/stderr -w "%{http_code}" "127.0.0.1:${PGHA_PATRONI_PORT}/master" 2> /dev/null)
            until [[ "${status_code}" == "200" ]]
            do
                sleep 1
                echo "Not yet running as primary, retrying" >> "/tmp/patroni_initialize_check.log"
                status_code=$(curl -o /dev/stderr -w "%{http_code}" "127.0.0.1:${PGHA_PATRONI_PORT}/master" 2> /dev/null)
            done

            echo_info "PGHA_INIT is '${PGHA_INIT}', executing post-init process to fully initialize the cluster"
            if [[ -f "/crunchyadm/pgha_manual_init" ]]
            then
                echo_info "Executing Patroni restart to restart database and update configuration"
                curl -X POST --silent "127.0.0.1:${PGHA_PATRONI_PORT}/restart"
                test_server "postgres" "${PGHOST}" "${PGPORT}" "postgres"
                echo_info "The database has been restarted"
            else
                echo "Pending restart not detected, will not restart" >> "/tmp/patroni_initialize_check.log"
            fi

            # Create the crunchyadm user
            if [[ "${PGHA_CRUNCHYADM}" == "true" ]]
            then
                echo_info "Creating user crunchyadm"
                psql -c "CREATE USER crunchyadm LOGIN;"
            fi
        else
            echo_info "PGHA_INIT is '${PGHA_INIT}', skipping post-init process "
        fi

        touch "/crunchyadm/pgha_initialized"  # write file to indicate the cluster is fully initialized
        echo_info "Node ${PATRONI_NAME} fully initialized for cluster ${PATRONI_SCOPE} and is ready for use"
    } &
}

# Waits for the primary node specified to be initialized prior to initializing the replica in order to
# orchestrate primary and replica placement
primary_initialization_monitor() {
    echo_info "Primary host specified, checking if Primary is ready before initializing replica"
    env_check_err "PGHA_PRIMARY_HOST"
    while [[ $(curl --silent "${PGHA_PRIMARY_HOST}:${PGHA_PATRONI_PORT}/master" --stderr - \
        | /opt/cpm/bin/yq r - state 2> /dev/null) != "running" ]]
    do
        echo_info "Primary is not ready, retrying"
        sleep 1
    done
    echo_info "Primary is ready, proceeding with initilization of replica"
}

# Remove the "pause" key from the patroni.dynamic.json if it exists.  This protects against
# Patroni being unable to initialize a restored cluster in the event that the backup utilized for
# the restore was taken while Patroni was paused, resulting in the "pause" key being present in the
# patroni.dynamic.json file contained with the backed up PGDATA directory (if the "pause" key is
# present, normal bootstrapping processes [e.g. leader election] will not occur, and the restored
# database will not be able to initialize).
remove_patroni_pause_key()  {
    if [[ -f "${PATRONI_POSTGRESQL_DATA_DIR}/patroni.dynamic.json" ]]
    then
        echo "Now removing \"pause\" key from patroni.dynamic.json configuration file if present"
        sed -i -e "s/\"pause\":\s*true,*\s*//" "${PATRONI_POSTGRESQL_DATA_DIR}/patroni.dynamic.json"
    fi
}

# Configure users and groups
source /opt/cpm/bin/common/uid_postgres_no_exec.sh

# Perform cluster pre-initialization (set defaults, load secrets, peform validation, log config details, etc.)
source /opt/cpm/bin/bootstrap/pre-bootstrap.sh

# Enable pgbackrest
if [[ "${PGHA_PGBACKREST}" == "true" ]]
then
    source /opt/cpm/bin/pgbackrest/pgbackrest-pre-bootstrap.sh
fi

# Enable SSHD if needed for a pgBackRest dedicated repository prior to bootstrapping
source /opt/cpm/bin/bootstrap/sshd.sh

if [[ -v PGHA_PRIMARY_HOST ]]
then
    primary_initialization_monitor
fi

# Start the database manually if creating a cluster from an existing database and not intitilizing a new one
if [[ ! -f "/crunchyadm/pgha_initialized" && "${PGHA_INIT}" == "true" && \
    -f "${PATRONI_POSTGRESQL_DATA_DIR}/PG_VERSION" ]]
then
    echo_info "Existing database found in PGDATA directory of initialization node"

    # If the Patroni bootstap configuration file is configured to use a custom PG config file using
    # the custom_config parameter, or if a postgresql.base.conf file is present in the PGDATA
    # directory, then assume those files are the base postgresql.conf parameters for the database
    # in accordance with the Patroni documentation for applying PG configuration to a cluster, and
    # therefore cleans out the contents of the existing postgresql.conf file if it exists (otherwise
    # an empty file will simply be created).  This ensures that the settings from previous Patroni
    # clusters that may no longer be valid (e.g. invalid dir names) do not prevent the DB from
    # starting successfully.  Once Patroni is initialized, the postgresql.conf will be populated
    # with the dynamic configuration defined for the cluster.
    # If a custom or base config file is not found, then the postgresql.conf will remain untouched,
    # and will then become the base configuration is accordance with the Patroni documentation.
    if [[ $(/opt/cpm/bin/yq r "/tmp/postgres-ha-bootstrap.yaml" postgresql.custom_conf) != "null" ]] ||
        [[ -f "${PATRONI_POSTGRESQL_DATA_DIR}/postgresql.base.conf" ]]
    then
        echo_info "Detected existing or custom base configuration for Patroni, cleaning postgresql.conf"
        > "${PATRONI_POSTGRESQL_DATA_DIR}/postgresql.conf"
    fi

    echo_info "Starting database manually prior to starting Patroni"
    while :
    do
        if ! pgrep --exact postgres &> /dev/null
        then
            # Start PostgreSQL in the background any time it is not running. It will exit if there
            # is an error during recovery, so start it again to retry. Allow only local connections
            # for now. PostgreSQL is restarted later, through Patroni, without these settings.
            pg_ctl start --silent -D "${PATRONI_POSTGRESQL_DATA_DIR}" \
                -o "-c listen_addresses='' -c unix_socket_directories='${PGHOST}'"
        fi

        # Check for ongoing recovery once connected. Since PostgreSQL 10, a hot standby allows
        # connections during recovery:
        # https://postgr.es/m/CABUevEyFk2cbpqqNDVLrgbHPEGLa%2BBV7nu4HAETBL8rK9Df_LA%40mail.gmail.com
        if pg_isready --quiet --username="postgres" &&
            [ "$(psql --quiet --username="postgres" -Atc 'SELECT pg_is_in_recovery()')" = 'f' ]
        then
            break
        else
            echo_info "Database has not reached a consistent state, sleeping..."
            sleep 5
        fi
    done
    echo_info "Reached a consistent state"

    touch "/crunchyadm/pgha_manual_init"
    echo_info "Manually creating Patroni accounts and proceeding with Patroni initialization"

    if [[ -f "/pgconf/post-existing-init.sql" ]]
    then
        post_existing_init_file="/pgconf/post-existing-init.sql"
    else
        post_existing_init_file="/opt/cpm/bin/sql/post-existing-init.sql"
    fi
    envsubst < ${post_existing_init_file} | psql -f -
fi

# Moinitor for the intialization of the cluster
initialization_monitor

# Remove the pause key from patroni.dynamic.json if it exists
remove_patroni_pause_key

# Bootstrap the cluster
bootstrap_cmd="$@ /tmp/postgres-ha-bootstrap.yaml"
echo_info "Initializing cluster bootstrap with command: '${bootstrap_cmd}'"
if [[ "$$" == 1 ]]
then
    echo_info "Running Patroni as PID 1"
    exec ${bootstrap_cmd}
else
    echo_info "Patroni will not run as PID 1. Creating signal handler"
    trap 'trap_sigterm' SIGINT SIGTERM
    ${bootstrap_cmd}
fi
