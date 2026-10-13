FROM postgres:16@sha256:ca0bd484cb98bf4b24eb1010e73fb3fcbd6714d240fbc1a10eea5b7dbecb641d

COPY olivier/init.sql /opt/inventory/init.sql
COPY olivier/bootstrap/bootstrap.sh /opt/inventory/bootstrap.sh
COPY infra/db-init.sh /usr/local/bin/db-init.sh
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sed -i 's/\r$//' /opt/inventory/bootstrap.sh /usr/local/bin/db-init.sh \
    && chmod 0555 /usr/local/bin/db-init.sh /opt/inventory/bootstrap.sh

ENTRYPOINT ["/usr/local/bin/db-init.sh"]
