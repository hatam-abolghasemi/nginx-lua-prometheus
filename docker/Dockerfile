ARG OPENRESTY_TAG
FROM openresty/openresty:${OPENRESTY_TAG}-alpine

# openssl: generate the baked fallback cert the :3129 ssl server needs to start
# and pass `openresty -t`. ca-certificates: the system trust bundle the
# interception leg verifies real upstreams against (proxy_ssl_trusted_certificate).
RUN apk add --no-cache openssl ca-certificates \
 && update-ca-certificates

COPY prometheus.lua prometheus_keys.lua prometheus_resty_counter.lua /opt/prometheus/
COPY lib/ /opt/prometheus/lib/
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/main.d/ /etc/nginx/main.d/
COPY docker/conf.d/ /etc/nginx/conf.d/

RUN ln -sf /etc/nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf \
 && mkdir -p /etc/nginx/main.d /etc/nginx/stream.d \
            /etc/nginx/intercept/ports /etc/nginx/intercept/bypass \
 && chmod -R a+rX /opt/prometheus \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout /etc/nginx/intercept/fallback.key \
        -out    /etc/nginx/intercept/fallback.crt \
        -subj   "/CN=openresty-intercept-fallback"

ENV APP_PORT=8080

EXPOSE 80 9145