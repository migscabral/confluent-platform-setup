ARG CFLT_REGISTRY
ARG CFLT_CP_VERSION
FROM ${CFLT_REGISTRY}/confluentinc/cp-server-connect:${CFLT_CP_VERSION}

USER root
COPY plugins/*.zip /tmp/plugins/
# Installs from the local zips; no Confluent Hub access at build or run time.
RUN for z in /tmp/plugins/*.zip; do \
      confluent-hub install --no-prompt --component-dir /usr/share/confluent-hub-components "$z" || exit 1; \
    done \
    && rm -rf /tmp/plugins \
    && chown -R appuser:appuser /usr/share/confluent-hub-components
USER appuser
