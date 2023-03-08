FROM postgres:13-alpine

RUN set -eux; \
    mkdir /config && chown postgres:postgres /config
    
COPY setup-slave.sh /docker-entrypoint-initdb.d/init.sh

VOLUME /config