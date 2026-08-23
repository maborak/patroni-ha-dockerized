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

[program:backup-logs]
command=/bin/bash -c "tail -f /var/log/backup/*.log 2>/dev/null || sleep infinity"
autostart=true
autorestart=true
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=20

[program:backup-cron]
command=/bin/bash -c "while true; do barman cron; sleep 60; done"
autostart=true
autorestart=true
user=backup
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=30

[program:backup-backup]
command=/bin/bash -c "sleep 300; while true; do for srv in __BACKUP_SERVERS__; do barman backup $$srv --wait 2>/dev/null; done; sleep 86400; done"
autostart=true
autorestart=true
user=backup
stderr_logfile=/dev/stderr
stderr_logfile_maxbytes=0
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
priority=40

