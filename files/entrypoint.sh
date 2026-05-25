#!/bin/sh
set -e

mkdir -p /tmp/cache/nginx \
         /tmp/cache/nginx-geoip \
         /tmp/logs/nginx \
         /tmp/nginx \
         /tmp/client_temp \
         /tmp/proxy_temp \
         /tmp/fastcgi_temp \
         /tmp/uwsgi_temp \
         /tmp/scgi_temp

exec nginx -c "/tmp/nginx/nginx.conf" -g "daemon off;"