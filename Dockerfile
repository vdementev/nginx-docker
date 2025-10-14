FROM alpine:3.22

RUN set -eux; \
    apk update; \
    apk upgrade --no-interactive; \
    apk add \
    ca-certificates \
    tzdata \
    nginx \
    nginx-mod-http-brotli; \
    rm -rf /var/cache/apk/*; \
    rm -rf /root/.cache; \
    rm -rf /tmp/*; \
    echo "net.core.rmem_max=2500000 " >> /etc/sysctl.conf; \
    echo "net.core.wmem_max=2500000 " >> /etc/sysctl.conf

COPY ./conf/nginx.conf /etc/nginx/nginx.conf

WORKDIR /app
EXPOSE 80/tcp
HEALTHCHECK --interval=5s --timeout=1s --start-period=10s --retries=3 CMD wget -q -O /dev/null http://127.0.0.1/ping || exit 1
STOPSIGNAL SIGQUIT
CMD ["nginx", "-g", "daemon off;"]