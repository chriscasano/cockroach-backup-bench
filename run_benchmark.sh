#!/bin/bash
# Backup / Restore Benchmarks

export cnodes=3
export CLUSTER="${USER:0:6}-${workload}"
export NODES=$(($NODES+1))
export AK=""
export SAK=""

### Create
roachprod create ${CLUSTER} -n ${NODES} -c aws #--local-ssd #--aws-machine-type-ssd=m5d.2xlarge
roachprod stage ${CLUSTER} workload
roachprod stage ${CLUSTER} release v20.1.0
roachprod start ${CLUSTER}:1-${cnodes} -a "--storage-engine=pebble"

### Admin UI
roachprod admin ${CLUSTER}:1 --open --ips

#echo "Run MOVR"
#roachprod run ${CLUSTER}:1 -- ./workload init movr --drop --data-loader=IMPORT --num-histories=10000000 --num-rides=50000000 --num-users=5000000 --num-vehicles=1000000 --num-ranges=256
#roachprod run ${CLUSTER}:4 -- ./workload run movr --duration=10m --display-every=30s --db "postgresql://root@127.0.0.1:26257/movr?sslmode=disable" &

echo "Init TPCC"
roachprod run ${CLUSTER}:4 -- ./workload fixtures import tpcc --warehouses 1000 --checks false "postgres://root@`roachprod ip ${CLUSTER}:1`:26258/tpcc?sslmode=disable"

echo "Starting Point"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "select count(*) as liveNodes from crdb_internal.gossip_nodes where is_live;" \
-e "select sum(range_size) / 1000000000 as dbSizeGB from crdb_internal.ranges where database_name = 'tpcc';"
EOF

echo "Run Idle TPCC backup"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database tpcc to 's3://chrisc-test/backup/tpcc-idle/?AUTH=specified&AWS_ACCESS_KEY_ID=${AK}&AWS_SECRET_ACCESS_KEY=${SAK}' as of system time '-10s' with revision_history;" \
-e "select finished - created as "backupFromCreate", finished - started as "backupFromStart" from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1);"
EOF

echo "Run TPCC Workload"
roachprod run ${CLUSTER}:4 "./workload run tpcc --warehouses=1000 --ramp=1m --duration=1h --display-every=1m {pgurl:1-3}" &

sleep 120

echo "Run Backup"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database tpcc to 's3://chrisc-test/backup/tpcc-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AK}&AWS_SECRET_ACCESS_KEY=${SAK}' as of system time '-10s' with revision_history;" \
-e "select finished - created as "backupFromCreate", finished - started as "backupFromStart" from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1);"
EOF

sleep 900

echo "Run Incremental 15"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database tpcc to 's3://chrisc-test/backup/tpcc-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AK}&AWS_SECRET_ACCESS_KEY=${SAK}' as of system time '-10s' with revision_history;" \
-e "select finished - created as "backupFromCreate", finished - started as "backupFromStart" from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1);"
EOF

sleep 900

echo "Run Incremental 30"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database tpcc to 's3://chrisc-test/backup/tpcc-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AK}&AWS_SECRET_ACCESS_KEY=${SAK}' as of system time '-10s' with revision_history;" \
-e "select finished - created as "backupFromCreate", finished - started as "backupFromStart" from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1);"
EOF
