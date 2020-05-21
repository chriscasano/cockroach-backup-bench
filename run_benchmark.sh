#!/bin/bash

if ( [ $# -eq 0 ] || [ $1 == "help" ] || [ $1 == "--help" ] ) then
    echo "Run CRDB backup and restore benchmarks using roachprod"
    echo "  Requirements: "
    echo "     - AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY envionment variables must be set"
    echo ""
    echo "  Parameters: "
    echo "    [backup_url] [provider(aws|gce)] [nodes(#)] [machine_type(m5d.xlarge)] [engine(peeble|default)] [workload(tpcc|movr)] [init_params(--warehouses 1000)] [run_params(--warehouses=1000)]"
    echo "    First option for each parameter is the default"
    exit 1;
fi

if ( [ $AWS_ACCESS_KEY_ID == "" ] || [ $AWS_SECRET_ACCESS_KEY == "" ]) then
    echo "AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY envionment variables must be set"
    exit 1;
fi

export backup_url=${1:-s3://chrisc-test/backup}
export provider=${2:-aws}
export cnodes=${3:-3}
export machine=${4:-m5d.xlarge}
export engine=${5:-pebble}
export workload=${6:-tpcc}
export init_p=${7:---warehouses=100 --checks=false}
export run_p=${8:---warehouses=100 --ramp=1m {pgurl:1-3\}}
if ( [ $provider == "aws" ] && [[ $machine == "m5d"* ]] ) then
  export ssd="-ssd "
else
  export ssd=""
fi

export CLUSTER="${USER:0:6}-${workload}"
export NODES=$(($cnodes+1))
export BUCKET=${workload}"-"${engine}

echo "**************************"
echo "Benchmarks Parameters"
echo "  Provider: $provider"
echo "  All Nodes: $NODES"
echo "  CRDB Nodes: $cnodes"
echo "  Machines: $machine"
echo "    SSD: $ssd"
echo "  Engine: $engine"
echo "  Workload: $workload"
echo "    $workload init: $init_p"
echo "    $workload run:  $run_p"
echo "  Cluster Name: $CLUSTER"
echo "  Backup Root: $backup_url"
echo "  Backup Bucket: $BUCKET"
echo "**************************"

### Remove prior backups
aws s3 rm ${backup_url}/${BUCKET}-idle/ --recursive --quiet
aws s3 rm ${backup_url}/${BUCKET}-live/ --recursive --quiet

### Create
roachprod create ${CLUSTER} -n ${NODES} -c ${provider} --${provider}-machine-type${ssd} ${machine}
roachprod stage ${CLUSTER} workload
roachprod stage ${CLUSTER} release v20.1.0
roachprod start ${CLUSTER}:1-${cnodes} -a "--storage-engine=${engine}"

### Admin UI
roachprod admin ${CLUSTER}:1 --open --ips

#echo "Run MOVR"
#roachprod run ${CLUSTER}:1 -- ./workload init movr --drop --data-loader=IMPORT --num-histories=10000000 --num-rides=50000000 --num-users=5000000 --num-vehicles=1000000 --num-ranges=256
#roachprod run ${CLUSTER}:4 -- ./workload run movr --duration=10m --display-every=30s --db "postgresql://root@127.0.0.1:26257/movr?sslmode=disable" &

echo "Init Workload"
roachprod run ${CLUSTER}:4 <<EOF
./workload fixtures import ${workload} ${init_p} "postgres://root@`roachprod ip ${CLUSTER}:1`:26257/tpcc?sslmode=disable"
EOF

sleep 15

echo "Initial Metrics"
roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${workload}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

echo "************************"
echo "Idle Backup"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${workload} to \"${backup_url}/${BUCKET}-idle/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${workload}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

echo "Run Workload"
roachprod run ${CLUSTER}:4 "./workload run ${workload} ${run_p} --display-every=1m {pgurl:1-3}" &

sleep 120

echo "************************"
echo "Live Backup"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${workload} to \"${backup_url}/${BUCKET}-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${workload}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

sleep 900

echo "************************"
echo "Incremental 15"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${workload} to \"${backup_url}/${BUCKET}-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${workload}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF

sleep 900

echo "************************"
echo "Incremental 30"
echo "************************"

roachprod run ${CLUSTER}:1 <<EOF
./cockroach sql --insecure \
-e "backup database ${workload} to \"${backup_url}/${BUCKET}-live/?AUTH=specified&AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}&AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}\" as of system time '-10s' with revision_history;" \
-e "select 'BackupDuration', extract_duration('second', finished - created)::DECIMAL from [show jobs] where job_id in (select job_id from [show jobs] where job_type = 'BACKUP' order by created desc limit 1) union all \
select 'LiveNodes' as metric, count(*)::DECIMAL as val from crdb_internal.gossip_nodes where is_live union all \
select 'DBSize', sum(range_size) / 1000000000 from crdb_internal.ranges where database_name = '${workload}' union all \
select 'NormCPU', avg(cast( metrics->>'sys.cpu.combined.percent-normalized' as DECIMAL )) from crdb_internal.kv_node_status;"
EOF


roachprod destroy ${CLUSTER}
