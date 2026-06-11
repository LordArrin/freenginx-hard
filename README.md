# freenginx-hard

This is a custom hardened build primarily for my personal use case

It includes freenginx with latest zlib-ng, mimalloc, PCRE2, openssl. 

```
nginx version: freenginx/1.31.2
built by gcc 15.2.0 (Alpine 15.2.0)
built with OpenSSL 4.0.1 9 Jun 2026
TLS SNI support enabled
configure arguments: --prefix=/usr/share/nginx --sbin-path=/usr/sbin/nginx --conf-path=/tmp/nginx/nginx.conf --error-log-path=/tmp/logs/nginx/error.log --http-log-path=/tmp/logs/nginx/access.log --pid-path=/tmp/nginx.pid --lock-path=/tmp/nginx.lock --http-client-body-temp-path=/tmp/client_temp --http-proxy-temp-path=/tmp/proxy_temp --http-fastcgi-temp-path=/tmp/fastcgi_temp --http-uwsgi-temp-path=/tmp/uwsgi_temp --http-scgi-temp-path=/tmp/scgi_temp --with-compat --with-http_auth_request_module --with-http_gunzip_module --with-http_gzip_static_module --with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module --with-http_sub_module --with-http_v2_module --with-http_v3_module --with-stream --with-stream_realip_module --with-stream_ssl_module --with-stream_ssl_preread_module --without-http_autoindex_module --without-http_browser_module --without-http_empty_gif_module --without-http_memcached_module --without-http_split_clients_module --without-http_ssi_module --without-http_userid_module --with-file-aio --with-threads --add-module=/tmp/ngx_brotli --add-module=/tmp/ngx_geoip2 --add-module=/tmp/ngx_headers_more --with-cc-opt='-I/usr/local/ssl/include -I/usr/local/zlib-ng/include -I/usr/local/pcre2/include -O3 -march=x86-64-v3 -mtune=alderlake -pipe -flto=auto -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 -fcf-protection=full -fno-plt -fno-semantic-interposition -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr -ftrapv -fno-delete-null-pointer-checks -fipa-pta -fno-math-errno -fmerge-all-constants -fPIE -grecord-gcc-switches -Wformat-security -Wno-error=strict-aliasing -Wno-error=vla-parameter -fomit-frame-pointer' --with-ld-opt='-L/usr/local/ssl/lib64 -L/usr/local/ssl/lib -L/usr/local/zlib-ng/lib -L/usr/local/pcre2/lib -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib -fuse-ld=mold -Wl,-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs -fcf-protection=full -flto=auto' --with-pcre-jit
```

Example config:
```
  nginx:
    image: lordarrin/freenginx-hard:latest
    container_name: nginx
    restart: unless-stopped
    network_mode: "host"
    security_opt: 
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp:size=2g,noexec,nosuid,mode=777
    volumes:
      - /etc/config/nginx:/tmp/nginx:noexec,nosuid,mode=644
      - /tmp/cache:/tmp/cache:noexec,nosuid,mode=777
    stop_grace_period: 10s
    deploy:
      resources:
        limits:
          memory: 4G
          cpus: '4'
```
