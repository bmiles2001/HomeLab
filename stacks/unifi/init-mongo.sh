#!/bin/bash
#
# Creates the UniFi application user in MongoDB, once, on first start.
#
# COPIED VERBATIM from linuxserver's documentation. Do not "improve" it:
#   https://docs.linuxserver.io/images/docker-unifi-network-application/
#
# It reads MONGO_* from the unifi-db container's environment, which
# scripts/deploy.sh fills from Infisical, so no credential is written here.
#
# Two things about how this runs, both of which have bitten people:
#
#   - The official mongo image only executes /docker-entrypoint-initdb.d/*
#     when /data/db is EMPTY. On any later start it is skipped without a word.
#     If the `unifi_db` volume already exists, this file does nothing and the
#     unifi container will fail authentication. Remove the volume and redeploy.
#
#   - The four databases below are not optional. UniFi opens unifi_stat,
#     unifi_audit and unifi_restore separately, and missing grants on any of
#     them present as the controller starting and then hanging rather than as
#     a permission error.

if which mongosh > /dev/null 2>&1; then
  mongo_init_bin='mongosh'
else
  mongo_init_bin='mongo'
fi
"${mongo_init_bin}" <<EOF
use ${MONGO_AUTHSOURCE}
db.auth("${MONGO_INITDB_ROOT_USERNAME}", "${MONGO_INITDB_ROOT_PASSWORD}")
db.createUser({
  user: "${MONGO_USER}",
  pwd: "${MONGO_PASS}",
  roles: [
    "clusterMonitor",
    { db: "${MONGO_DBNAME}", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_stat", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_audit", role: "dbOwner" },
    { db: "${MONGO_DBNAME}_restore", role: "dbOwner" }
  ]
})
EOF
