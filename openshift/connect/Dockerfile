ARG CFLT_REGISTRY
ARG CFLT_CP_VERSION
FROM ${CFLT_REGISTRY}/confluentinc/cp-server-connect:${CFLT_CP_VERSION}

USER root
COPY plugins/*.zip /tmp/plugins/
# drivers/ must exist (it may be empty); jars go on the JDBC connector's own classpath.
COPY drivers/ /tmp/drivers/
# Installs from the local zips; no Confluent Hub access at build or run time.
RUN for z in /tmp/plugins/*.zip; do \
      confluent-hub install --no-prompt --component-dir /usr/share/confluent-hub-components "$z" || exit 1; \
    done \
    && if ls /tmp/drivers/*.jar >/dev/null 2>&1; then \
         cp /tmp/drivers/*.jar /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/ || exit 1; \
       fi \
    && rm -rf /tmp/plugins /tmp/drivers \
    && chown -R appuser:appuser /usr/share/confluent-hub-components
USER appuser
