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

source /opt/cpm/bin/common/common_lib.sh
enable_debugging

source /opt/cpm/bin/common/pgha-common.sh
export $(get_patroni_pgdata_dir)

# If the PGDATA directory is empty or contains a valid PG database, then perform a delta restore.
# If the PGDATA directory for the replica is invalid according to pgBackRest, then clear out
# the directory and then perform a regular (i.e. non-delta) pgBackRest restore.  pgBackRest
# specifically determines whether or not a PGDATA directory is valid by checking "for the
# for the presence of PG_VERSION or backup.manifest (left over from an aborted restore). 
# If neither file is found then --delta and --force will be disabled but the restore will proceed
# unless there are files in the $PGDATA directory (or any tablespace directories) in which case the
# operation will be aborted" (https://pgbackrest.org/release.html).
if [[ -f "${PATRONI_POSTGRESQL_DATA_DIR}"/PG_VERSION || 
    -f "${PATRONI_POSTGRESQL_DATA_DIR}"/backup.manifest ]]
then
    echo_info "Valid PGDATA dir found for replica, a delta restore will be peformed"
    delta="--delta"
elif [[ -z "$(ls -A ${PATRONI_POSTGRESQL_DATA_DIR})" ]]
then
    echo_info "Empty PGDATA dir found for replica, a non-delta restore will be peformed"

    # create the PGDATA directory if needed (e.g. in the event it was deleted)
    # and set the proper permissions
    if [[ ! -d "${PATRONI_POSTGRESQL_DATA_DIR}" ]]
    then
        mkdir -p "${PATRONI_POSTGRESQL_DATA_DIR}"
        chmod 0700 "${PATRONI_POSTGRESQL_DATA_DIR}"
    fi
else
    echo_info "Invalid PGDATA directory found for replica, cleaning prior to restore"
    while [[ ! -z "$(ls -A ${PATRONI_POSTGRESQL_DATA_DIR})" ]]
    do
        echo_info "Files still found in PGDATA, attempting cleanup"
        rm -rf "${PATRONI_POSTGRESQL_DATA_DIR:?}"/*
        sleep 3
    done
    echo_info "Replica PGDATA cleaned, a non-delta restore will be peformed"
fi

# obtain the type of repo to use for replica creation (e.g. AWS S3 or local) using the value set
# the 'replica-bootstrap-repo-type' configuration file (if present), and then set the repo type
# for the pgBackRest restore command as applicable using the --repo-type option
if [[ -f /pgconf/replica-bootstrap-repo-type ]]
then
    replica_bootstrap_repo_type="$(cat /pgconf/replica-bootstrap-repo-type)"
    if [[ "${replica_bootstrap_repo_type}" != "" ]]
    then
        restore_cmd_repo_type="--repo-type=${replica_bootstrap_repo_type}"
    fi
fi

# perform the restore, setting the "--delta" option if populated
pgbackrest restore ${delta} ${restore_cmd_repo_type}
err_check "$?" "pgBackRest Replica Creation" "pgBackRest restore failed when creating replica"

echo_info "Replica pgBackRest restore complete"
