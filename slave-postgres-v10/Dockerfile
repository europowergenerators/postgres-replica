FROM postgres:10-alpine

RUN mkdir -p /config && \
    chown postgres:postgres /config

COPY setup_slave.sh /docker-entrypoint-initdb.d/init.sh

VOLUME /config