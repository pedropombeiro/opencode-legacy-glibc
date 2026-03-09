FROM debian:stretch-slim

RUN sed -i 's|deb.debian.org/debian|archive.debian.org/debian|g' /etc/apt/sources.list \
    && sed -i 's|security.debian.org/debian-security|archive.debian.org/debian-security|g' /etc/apt/sources.list \
    && sed -i '/stretch-updates/d' /etc/apt/sources.list \
    && echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99no-check-valid \
    && apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

ARG OPENCODE_DIR=out
COPY ${OPENCODE_DIR}/opencode /opt/opencode
COPY build/test/test-env.sh /opt/test-env.sh

ENV PATH="/opt/opencode/bin:${PATH}"

CMD ["opencode"]
