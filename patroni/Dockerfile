FROM postgres:15

# Install dependencies
RUN apt-get update && apt-get install -y \
    python3 \
    python3-pip \
    python3-psycopg2 \
    curl \
    netcat-openbsd \
    openssh-server \
    openssh-client \
    barman-cli \
    rsync \
    supervisor \
    && rm -rf /var/lib/apt/lists/*

# Install setuptools first (required for some dependencies)
RUN pip3 install --break-system-packages --no-cache-dir setuptools

# Install Patroni with etcd3 support
RUN pip3 install --break-system-packages --no-cache-dir patroni[etcd3] psycopg2-binary

# Create directories and set permissions
RUN mkdir -p /etc/patroni /home/postgres/.ssh /etc/supervisor/conf.d /var/run/sshd /var/log/postgresql && \
    chown -R postgres:postgres /etc/patroni /home/postgres/.ssh /var/log/postgresql && \
    chmod 700 /home/postgres/.ssh && \
    chmod 755 /var/log/postgresql

# Configure SSH for key-based access
RUN ssh-keygen -A && \
    echo "PermitRootLogin no" >> /etc/ssh/sshd_config && \
    echo "PasswordAuthentication no" >> /etc/ssh/sshd_config && \
    echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config && \
    echo "AuthorizedKeysFile .ssh/authorized_keys" >> /etc/ssh/sshd_config && \
    echo "StrictModes no" >> /etc/ssh/sshd_config && \
    echo "LogLevel INFO" >> /etc/ssh/sshd_config

# Copy entrypoint script and supervisor config
COPY entrypoint.sh /entrypoint.sh
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
RUN chmod +x /entrypoint.sh

# Set working directory
WORKDIR /var/lib/postgresql

# Expose PostgreSQL, Patroni REST API, and SSH ports
EXPOSE 5431 8001 22

# Note: Container runs as root to manage supervisor, but Patroni runs as postgres user via supervisor
# Use entrypoint to set permissions before running supervisor
ENTRYPOINT ["/entrypoint.sh"]

# Default command - run supervisor
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisor/conf.d/supervisord.conf", "-n"]

