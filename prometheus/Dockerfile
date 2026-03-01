ARG PROMETHEUS_VERSION=latest
FROM prom/prometheus:${PROMETHEUS_VERSION}

# Copy configuration
COPY prometheus.yml /etc/prometheus/prometheus.yml

USER nobody
