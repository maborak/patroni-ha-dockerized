ARG ALPINE_VERSION=3.22
FROM docker.io/library/alpine:${ALPINE_VERSION}

# pgBadger release (github.com/darold/pgbadger tags, without the leading v).
# Installed from the upstream tarball so we are not tied to Alpine's packaged
# version, which lags behind (e.g. 3.20 shipped 12.4 while 13.x was current).
ARG PGBADGER_VERSION=13.2

# perl is pgbadger's undeclared runtime dep; darkhttpd serves the UI;
# curl+ca-certificates fetch the upstream tarball at build time.
RUN apk add --no-cache perl tzdata darkhttpd ca-certificates curl \
    && curl -fsSL "https://github.com/darold/pgbadger/archive/refs/tags/v${PGBADGER_VERSION}.tar.gz" \
        | tar xz -C /tmp \
    && install -m 755 "/tmp/pgbadger-${PGBADGER_VERSION}/pgbadger" /usr/local/bin/pgbadger \
    && rm -rf "/tmp/pgbadger-${PGBADGER_VERSION}" \
    && pgbadger --version

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY collect.sh /usr/local/bin/collect.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/collect.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
