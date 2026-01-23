FROM postgres:15

# Install Barman, PostgreSQL client, supervisor, and pgBadger
RUN apt-get update && apt-get install -y \
    barman \
    postgresql-client \
    openssh-server \
    openssh-client \
    rsync \
    supervisor \
    pigz \
    pgbadger \
    && rm -rf /var/lib/apt/lists/*

# Configure SSH for key-based access (for archive_command)
RUN mkdir -p /var/run/sshd /home/barman/.ssh && \
    ssh-keygen -A && \
    chmod 700 /home/barman/.ssh && \
    chown -R barman:barman /home/barman/.ssh

# SSH configuration
RUN echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config && \
    echo "StrictModes no" >> /etc/ssh/sshd_config && \
    echo "LogLevel INFO" >> /etc/ssh/sshd_config

# Create Barman directories and pgBadger reports directory
RUN mkdir -p /var/lib/barman /var/log/barman /etc/barman.d /data/pg-backup /var/lib/barman/pgbadger-reports

# Create barman user if it doesn't exist
RUN useradd -m -s /bin/bash barman || true

# Set permissions
RUN chown -R barman:barman /var/lib/barman /var/log/barman /data/pg-backup /var/lib/barman/pgbadger-reports

# Expose PostgreSQL port (for barman streaming)
EXPOSE 5432

# Create supervisor directory
RUN mkdir -p /etc/supervisor/conf.d

# Copy entrypoint script and supervisor config
COPY entrypoint.sh /entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /entrypoint.sh

# Start supervisor
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf", "-n"]

