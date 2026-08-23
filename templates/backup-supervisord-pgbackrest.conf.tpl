[supervisord]
nodaemon=true
user=root
logfile=/dev/stdout
logfile_maxbytes=0
pidfile=/var/run/supervisord.pid

[program:sshd]
command=/usr/sbin/sshd -D
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=10

[program:pgbackrest-cron]
; Nightly incremental per server (pgBackRest auto-upgrades to full when the
; retention policy requires it). Staggered start to avoid overlapping.
command=/bin/bash -c "sleep 300; while true; do for srv in __BACKUP_SERVERS__; do pgbackrest --stanza=$$srv --type=incr backup 2>>/var/log/pgbackroot/cron.log; done; sleep 86400; done"
autostart=true
autorestart=true
user=backup
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=40

[program:pgbackrest-full-weekly]
; Weekly full backup (Sunday 02:00-ish via sleep offset from container start)
command=/bin/bash -c "while true; do for srv in __BACKUP_SERVERS__; do pgbackrest --stanza=$$srv --type=full backup 2>>/var/log/pgbackroot/full.log; done; sleep 604800; done"
autostart=true
autorestart=true
user=backup
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=41
