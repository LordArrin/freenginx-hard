FROM alpine:latest

ARG BUILD_VERSION=1.31.1
ARG OPENSSL_VERSION=4.0.0
ARG PCRE_VERSION=10.47
ARG MIMALLOC_VERSION=3.3.2
ARG ZLIB_NG_VERSION=2.3.3
ARG BROTLI_URL=https://github.com/wxx9248/ngx_brotli.git
ARG GEOIP2_URL=https://github.com/leev/ngx_http_geoip2_module.git
ARG GEOIP2_BASE_URL=https://github.com/mojolabs-id/GeoLite2-Database
ARG HEADERS_MORE_URL=https://github.com/openresty/headers-more-nginx-module.git

LABEL org.opencontainers.image.title="Freenginx Proxy" \
      org.opencontainers.image.description="Freenginx proxy with proper hardening" \
      org.opencontainers.image.version="1.4" \
      org.opencontainers.image.source="https://github.com/LordArrin/freenginx-hard"

ENV LD_PRELOAD=/usr/lib/libmimalloc.so.2

RUN \
  set -euxo pipefail && \
  apk update && \
  apk upgrade --no-cache && \
  \
  # Base packages
  runtime_pkgs="ca-certificates tzdata libgcc libmaxminddb" && \
  apk --no-cache add ${runtime_pkgs} && \
  update-ca-certificates && \
  \
  # Build apks to meta .build-deps
  build_pkgs="build-base linux-headers fortify-headers ccache wget perl git mold cmake libmaxminddb-dev" && \
  apk --no-cache add --virtual .build-deps ${build_pkgs} && \
  \
  cd /tmp && \
  
  # Arch selection
  NB_PROC=$(grep -c ^processor /proc/cpuinfo) && \
  ARCH=$(uname -m); \
  case "$ARCH" in \
    x86_64) MARCH="x86-64-v3"; MTUNE="alderlake"; CFI_FLAGS="-fcf-protection=full" ;; \
    aarch64) MARCH="armv8.2-a+crypto+crc+lse+rdma"; MTUNE="generic"; CFI_FLAGS="-mbranch-protection=standard" ;; \
    *) MARCH="native"; MTUNE="generic"; CFI_FLAGS="" ;; \
  esac; \
  echo "Building for $ARCH -> march=$MARCH | mtune=$MTUNE | cfi=$CFI_FLAGS"; \
  
  wget -O - https://freenginx.org/download/freenginx-${BUILD_VERSION}.tar.gz --tries=3 | tar zxf - -C /tmp && \
  wget -O - https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
  wget -O - https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
  
  git clone --depth 1 ${BROTLI_URL} /tmp/ngx_brotli && \
  cd /tmp/ngx_brotli && \
  git submodule update --init && \
  
  # Building brotli library
  cd /tmp/ngx_brotli/deps/brotli && \
  mkdir -p out && cd out && \
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="-O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} -flto=auto -fPIC -fno-plt -fno-semantic-interposition" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} -flto=auto" \
    -DCMAKE_INSTALL_PREFIX=./installed \
    .. && \
  PATH="/usr/lib/ccache:${PATH}" cmake --build . --config Release --target brotlienc && \
  
  git clone --depth 1 ${GEOIP2_URL} /tmp/ngx_geoip2 && \
  mkdir -p /etc/nginx/geoip && \
  wget -O /etc/nginx/geoip/GeoLite2-Country.mmdb \
       ${GEOIP2_BASE_URL}/releases/latest/download/GeoLite2-Country.mmdb && \
  git clone --depth 1 ${HEADERS_MORE_URL} /tmp/ngx_headers_more && \
  
  # Building mimalloc
  git clone --depth 1 -b v${MIMALLOC_VERSION} https://github.com/microsoft/mimalloc.git /tmp/mimalloc && \
  cd /tmp/mimalloc && \
  mkdir -p out/release && cd out/release && \
  cmake -DCMAKE_BUILD_TYPE=Release \
        -DMI_SECURE=ON \
        -DMI_BUILD_SHARED=ON \
        -DMI_BUILD_STATIC=OFF \
        -DMI_BUILD_TESTS=OFF \
        -DMI_BUILD_OBJECT=OFF \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_C_FLAGS="-O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} -flto=auto -fPIC -fno-plt -fno-semantic-interposition" \
        -DCMAKE_SHARED_LINKER_FLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} -flto=auto" \
        ../.. && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install && \
  
  # Building openssl
  cd /tmp/openssl-${OPENSSL_VERSION} && \  
  ./config \
    --prefix=/usr/local/ssl \
    --openssldir=/usr/local/ssl \
    shared \
    enable-quic enable-tfo enable-pie no-tests \
    -O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fomit-frame-pointer \
    -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 \
    -grecord-gcc-switches -fno-plt -fno-semantic-interposition \
    -Wformat-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 \
    -DOPENSSL_TLS_SECURITY_LEVEL=3 ${CFI_FLAGS} \
    -fuse-ld=mold -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install_sw install_ssldirs && \
  
  # Building zlib-ng
  git clone --depth 1 -b ${ZLIB_NG_VERSION} https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng && \
  cd /tmp/zlib-ng && \
  mkdir -p build && cd build && \
  cmake \
    -DCMAKE_INSTALL_PREFIX=/usr/local/zlib-ng \
    -DZLIB_COMPAT=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DZLIB_ENABLE_TESTS=OFF \
    -DWITH_OPTIM=ON \
    -DWITH_NEW_STRATEGIES=ON \
    -DCMAKE_C_FLAGS="-O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} -flto=auto -fPIC -fno-plt -fno-semantic-interposition" \
    -DCMAKE_EXE_LINKER_FLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} -flto=auto" \
    .. && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install && \
  ln -sf /usr/local/zlib-ng/include/zlib.h /usr/include/zlib.h && \
  ln -sf /usr/local/zlib-ng/include/zconf.h /usr/include/zconf.h && \
  
  # Building nginx
  cd /tmp/freenginx-${BUILD_VERSION} && \
  ./configure \
    --prefix=/usr/share/nginx \
    --sbin-path=/usr/sbin/nginx \
    --conf-path=/tmp/nginx/nginx.conf \
    --error-log-path=/tmp/logs/nginx/error.log \
    --http-log-path=/tmp/logs/nginx/access.log \
    --pid-path=/tmp/nginx.pid \
    --lock-path=/tmp/nginx.lock \
    --http-client-body-temp-path=/tmp/client_temp \
    --http-proxy-temp-path=/tmp/proxy_temp \
    --http-fastcgi-temp-path=/tmp/fastcgi_temp \
    --http-uwsgi-temp-path=/tmp/uwsgi_temp \
    --http-scgi-temp-path=/tmp/scgi_temp \
    --with-compat \
    --with-http_auth_request_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --without-http_autoindex_module \
    --without-http_browser_module \
    --without-http_empty_gif_module \
    --without-http_split_clients_module \
    --without-http_ssi_module \
    --with-file-aio \
    --with-threads \
    --add-module=/tmp/ngx_brotli \
    --add-module=/tmp/ngx_geoip2 \
    --add-module=/tmp/ngx_headers_more \
    --with-cc-opt="-I/usr/local/ssl/include -I/usr/local/zlib-ng/include -O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -grecord-gcc-switches -fPIE -pie -fno-plt -fno-semantic-interposition -Wformat-security -Wno-error=strict-aliasing -Wno-error=vla-parameter -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} -flto=auto -fomit-frame-pointer" \
    --with-ld-opt="-L/usr/local/ssl/lib64 -L/usr/local/ssl/lib -L/usr/local/zlib-ng/lib -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib -fuse-ld=mold -O3 -fPIE -Wl,-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} -flto=auto" \
    --with-pcre-jit \
    --with-pcre=/tmp/pcre2-${PCRE_VERSION} \
    && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  ccache -s && \
  strip --strip-unneeded objs/nginx && \
  make install && \
  ln -sf /usr/local/ssl/bin/openssl /usr/sbin/openssl && \
  ln -sf /usr/local/ssl/bin/c_rehash /usr/sbin/c_rehash && \
  addgroup -S nginx && \
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
  \
  # Cleanup
  rm -rf /tmp/* /var/cache/apk/* /root/.ccache && \
  apk del --no-network .build-deps

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 80/tcp
EXPOSE 443/tcp
EXPOSE 443/udp

USER nginx

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]