FROM alpine:latest

RUN set -eux; \
    apk add --no-cache ca-certificates shadow su-exec autossh openssh-client

RUN set -eux; \
    addgroup -S autossh && \
    adduser -h /config -s /bin/false -S autossh -G autossh
    
VOLUME /config

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
