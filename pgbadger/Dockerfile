FROM alpine:3.20

# pgbadger: log analyzer (community repo); perl: its undeclared runtime dep;
# darkhttpd: tiny static file server for the UI
RUN apk add --no-cache pgbadger perl tzdata darkhttpd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY collect.sh /usr/local/bin/collect.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/collect.sh

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
