ARG NANOMQ_VERSION=latest
FROM emqx/nanomq:${NANOMQ_VERSION}

ENV NANOMQ_CONF_PATH=/etc/nanomq/nanomq.conf

COPY nanomq.conf /etc/nanomq/nanomq.conf
COPY nanomq_acl.conf /etc/nanomq/nanomq_acl.conf
