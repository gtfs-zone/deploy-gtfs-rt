ARG NANOMQ_VERSION=latest
FROM emqx/nanomq:${NANOMQ_VERSION}

COPY nanomq.conf /etc/nanomq.conf
COPY acl.conf /etc/nanomq-acl.conf
COPY entrypoint.sh /etc/nanomq-entrypoint.sh

ENTRYPOINT ["/bin/sh", "/etc/nanomq-entrypoint.sh"]
