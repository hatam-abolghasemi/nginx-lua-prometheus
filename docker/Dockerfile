ARG OPENRESTY_TAG
FROM openresty/openresty:${OPENRESTY_TAG}-alpine

COPY prometheus.lua prometheus_keys.lua prometheus_resty_counter.lua /opt/prometheus/
COPY lib/ /opt/prometheus/lib/
COPY docker/nginx.conf /etc/nginx/nginx.conf
COPY docker/conf.d/ /etc/nginx/conf.d/

RUN ln -sf /etc/nginx/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf \
 && mkdir -p /etc/nginx/main.d /etc/nginx/stream.d

ENV APP_PORT=8080

EXPOSE 80 9145
