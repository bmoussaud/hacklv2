FROM mcr.microsoft.com/azure-cli:2.77.0@sha256:d41153958a61392a4c9db1591e33b533ca8ab8b59529d212d06bb6ec7e9c1f25

RUN tdnf install -y ca-certificates postgresql coreutils \
    && tdnf clean all
COPY backup.sh /usr/local/bin/backup.sh
COPY restore.sh /usr/local/bin/restore.sh
RUN sed -i 's/\r$//' /usr/local/bin/backup.sh /usr/local/bin/restore.sh \
    && chmod 0555 /usr/local/bin/backup.sh /usr/local/bin/restore.sh

ENV HOME=/tmp \
    AZURE_CONFIG_DIR=/tmp/azure-cli \
    PGSSLROOTCERT=/etc/pki/tls/certs/ca-bundle.crt
USER 10001:10001
ENTRYPOINT ["/usr/local/bin/backup.sh"]
