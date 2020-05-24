# CockroachDB Backup & Restore Benchmarking

This benchmarking script uses roachprod to test CockroachDB's backup and restore processes.  It's generic enough to run different workloads while backup and restore run.

## What Does The Script Do?
- Removes prior backups in S3
- Creates the envionrment
- Initialize a workload
- Takes an idle backups
- Runs tbe workload
- Takes a working backup
- Takes a working incremental backup 15 minutes later
- Takes a working incremental backup 30 minutes later
- Stops the workload
- Runs an idle restore

### Roadmap
- Full cluster backups
- Incremental / Point In Time Restores
- Backups on long running clusters

### Limitations
- This works for AWS only today
- Tested with `tpcc` only, but should work for other workloads

### Dependencies
- roachprod
- aws cli

### How To Run It

- Clone repo
- Ensure aws cli and roachprod are configured
- Create a S3 bucket to store backups
- Set AWS_ACCESS_KEY_ID & AWS_SECRET_ACCESS_KEY in your environment variables
- Run the script

`./run_benchmark.sh s3://mybucket/backup aws 3 m5d.xlarge pebble tpcc "--warehouses=100 --checks=false" "--warehouses=100 --ramp=1m" > tpcc-100-pebble-1.log 2>&1`

## Parameters

The first option for each parameter is the default

[s3 backup url (s3://mybucket/backup)]  
[provider (aws|gce)]  
[nodes (#)]  
[machine_type (m5d.xlarge)]  
[engine (pebble|default)]  
[workload (tpcc|movr)]  <-- other workloads should work here   
[init_params (--warehouses=100)]  
[run_params (--warehouses=100)]  
