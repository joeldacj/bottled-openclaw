# Pinned by digest for reproducible builds (tag 2026.9.7); bump to upgrade.
FROM ghcr.io/openclaw/openclaw:2026.9.7@sha256:0da12cd49983fcb5e4915fd3135ce7a33d82f93649b1df6964946d2c1d1dbcfc

USER root

COPY entrypoint.sh /openhost-entrypoint.sh
RUN chmod +x /openhost-entrypoint.sh \
    && rm -rf /home/node/.openclaw

EXPOSE 18789

ENTRYPOINT ["/openhost-entrypoint.sh"]
CMD ["docker-entrypoint.sh", "node", "openclaw.mjs", "gateway", "--allow-unconfigured"]
