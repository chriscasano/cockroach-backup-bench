#!/bin/bash

if ( [ $# -eq 0 ] || [ $1 == "help" ] || [ $1 == "--help" ] ) then
    echo "Run CRDB backup and restore benchmarks using roachprod"
    echo "  Requirements: "
    echo "     - AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY envionment variables must be set"
    echo ""
    echo "  Parameters: "
    echo "    [BACKUP_URL] [provider(aws|gce)] [nodes(#)] [machine_type(m5d.xlarge)] [engine(peeble|default)] [workload(tpcc|movr)] [init_params(--warehouses 100)] [run_params(--warehouses=100)]"
    echo "    First option for each parameter is the default"
    exit 1;
fi

if ( [ $AWS_ACCESS_KEY_ID == "" ] || [ $AWS_SECRET_ACCESS_KEY == "" ]) then
    echo "AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY envionment variables must be set"
    exit 1;
fi

export BACKUP_URL=${1:-s3://chrisc-test/backup}
export PROVIDER=${2:-aws}
export CNODES=${3:-3}
export MACHINE=${4:-m5d.xlarge}
export ENGINE=${5:-pebble}
export WORKLOAD=${6:-tpcc}
export INIT_P=${7:---warehouses=100 --checks=false }
export RUN_P=${8:---warehouses=100 --ramp=1m }
if ( [ $PROVIDER == "aws" ] && [[ $MACHINE == "m5d"* ]] ) then
  export ssd="-ssd "
else
  export ssd=""
fi

export CLUSTER="${USER:0:6}-${WORKLOAD}"
export NODES=$(($CNODES+1))
export BUCKET=${WORKLOAD}"-"${ENGINE}

echo "**************************"
echo "Benchmarks Parameters"
echo "  Provider: $PROVIDER"
echo "  All Nodes: $NODES"
echo "  CRDB Nodes: $CNODES"
echo "  Machines: $MACHINE"
echo "    SSD: $ssd"
echo "  Engine: $ENGINE"
echo "  Workload: $WORKLOAD"
echo "    $WORKLOAD init: $INIT_P"
echo "    $WORKLOAD run:  $RUN_P"
echo "  Cluster Name: $CLUSTER"
echo "  Backup Root: $BACKUP_URL"
echo "  Backup Bucket: $BUCKET"
echo "**************************"

### Remove prior backups
#aws s3 rm ${BACKUP_URL}/${BUCKET}-idle-temp/ --recursive --quiet
#aws s3 rm ${BACKUP_URL}/${BUCKET}-live-temp/ --recursive --quiet

### Create
roachprod create ${CLUSTER} -n ${NODES} -c ${PROVIDER} --${PROVIDER}-machine-type${ssd} ${MACHINE}
roachprod stage ${CLUSTER} workload
roachprod stage ${CLUSTER} release v20.1.0
roachprod start ${CLUSTER}:1-${CNODES} -a "--storage-engine=${engine}"

### Admin UI
roachprod admin ${CLUSTER}:1 --open --ips

#echo "Run MOVR"
#roachprod run ${CLUSTER}:1 -- ./workload init movr --drop --data-loader=IMPORT --num-histories=10000000 --num-rides=50000000 --num-users=5000000 --num-vehicles=1000000 --num-ranges=256
#roachprod run ${CLUSTER}:4 -- ./workload run movr --duration=10m --display-every=30s --db "postgresql://root@127.0.0.1:26257/movr?sslmode=disable" &

echo "Init Workload"
roachprod run ${CLUSTER}:4 <<EOF
./workload fixtures import ${WORKLOAD} ${INIT_P} "postgres://root@`roachprod ip ${CLUSTER}:1`:26257/tpcc?sslmode=disable"
EOF

sleep 15

echo "Initial Metrics"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

echo "************************"
echo "Idle Backup"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${WORKLOAD} to \"${BACKUP_URL}/${BUCKET}-idle-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

echo "Run Workload"
roachprod run ${CLUSTER}:${NODES} -- "./workload run ${WORKLOAD} ${RUN_P} --display-every=1m {pgurl:1-${CNODES}}" &
BGPID=$!

sleep 120

echo "************************"
echo "Live Backup"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${WORKLOAD} to \"${BACKUP_URL}/${BUCKET}-live-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

sleep 900

echo "************************"
echo "Incremental 15"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${WORKLOAD} to \"${BACKUP_URL}/${BUCKET}-live-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

sleep 900

echo "************************"
echo "Incremental 30"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${WORKLOAD} to \"${BACKUP_URL}/${BUCKET}-live-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

echo "************************"
echo "Show Backups"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "show backup \"${BACKUP_URL}/${BUCKET}-live-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\";"
EOF

echo "************************"
echo "Stop Workload"
echo "************************"

kill -9 $BGPID
roachprod run ${CLUSTER}:4 -- pkill -9 workload

echo "************************"
echo "Restore Idle"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "drop database ${WORKLOAD};" \
-e "select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${WORKLOAD}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;" \
-e "restore database ${WORKLOAD} from \"${BACKUP_URL}/${BUCKET}-live-temp/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\";" \
-e "select 'RestoreDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'RESTORE' order by created desc limit 1);"
EOF

roachprod destroy ${CLUSTER}
