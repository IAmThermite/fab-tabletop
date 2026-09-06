FROM coturn/coturn:4.17.2-debian

COPY infrastructure/coturn/turnserver.conf /etc/coturn/turnserver.conf
COPY infrastructure/coturn/entrypoint.sh /usr/local/bin/entrypoint.sh

USER root
RUN chmod +x /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
