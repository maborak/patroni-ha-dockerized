[barman]
;barman_lock_directory = /var/run/barman

; Log location
log_file = /var/log/barman/barman.log

; Log level (see https://docs.python.org/3/library/logging.html#levels)
log_level = INFO

; Pre/post backup hook scripts
;pre_backup_script = env | grep ^BARMAN
;pre_backup_retry_script = env | grep ^BARMAN
;post_backup_retry_script = env | grep ^BARMAN
;post_backup_script = env | grep ^BARMAN

; Pre/post archive hook scripts
;pre_archive_script = env | grep ^BARMAN
;pre_archive_retry_script = env | grep ^BARMAN
;post_archive_retry_script = env | grep ^BARMAN
;post_archive_script = env | grep ^BARMAN

; Pre/post delete scripts
;pre_delete_script = env | grep ^BARMAN
;pre_delete_retry_script = env | grep ^BARMAN
;post_delete_retry_script = env | grep ^BARMAN
;post_delete_script = env | grep ^BARMAN

; Pre/post wal delete scripts
;pre_wal_delete_script = env | grep ^BARMAN
;pre_wal_delete_retry_script = env | grep ^BARMAN
;post_wal_delete_retry_script = env | grep ^BARMAN
;post_wal_delete_script = env | grep ^BARMAN

; Global bandwidth limit in kilobytes per second - default 0 (meaning no limit)
bandwidth_limit = __BARMAN_BANDWIDTH_LIMIT__

; Number of parallel jobs for backup and recovery via rsync (default 1)
parallel_jobs = __BARMAN_PARALLEL_JOBS__

; Immediate checkpoint for backup command - default false
immediate_checkpoint = true

; Enable network compression for data transfers - default false
network_compression = true

; Number of retries of data copy during base backup after an error - default 0
basebackup_retry_times = 2

; Number of seconds of wait after a failed copy, before retrying - default 30
basebackup_retry_sleep = 10

; Maximum execution time, in seconds, per server
;check_timeout = 30

; Time frame that must contain the latest backup date.
last_backup_maximum_age = 1 DAYS

; Time frame that must contain the latest WAL file
last_wal_maximum_age = 1 HOURS

barman_user = barman
barman_home = /data/pg-backup
compression = pigz
reuse_backup = copy
wal_retention_policy = main
backup_method = rsync
backup_options = concurrent_backup
minimum_redundancy = 1
retention_policy = __BARMAN_RETENTION_POLICY__

__DB_SECTIONS__
