# ==========================================
# Stage 1: Builder
# ==========================================
FROM alpine:latest AS builder

ARG BUILD_VERSION=1.31.3
ARG OPENSSL_VERSION=4.0.1
ARG PCRE_VERSION=10.47
ARG MIMALLOC_VERSION=3.4.5
ARG ZLIB_NG_VERSION=2.3.3
ARG BROTLI_URL=https://github.com/wxx9248/ngx_brotli.git
ARG GEOIP2_URL=https://github.com/kraloveckey/nginx-geoip2.git
ARG GEOIP2_BASE_URL=https://github.com/mojolabs-id/GeoLite2-Database
ARG HEADERS_MORE_URL=https://github.com/openresty/headers-more-nginx-module.git

RUN \
  set -euxo pipefail && \
  apk update && \
  apk upgrade --no-cache && \
  build_pkgs="build-base linux-headers fortify-headers ccache wget perl git mold cmake libmaxminddb-dev" && \
  apk --no-cache add --virtual .build-deps ${build_pkgs} && \
  \
  cd /tmp && \
  \
  # Arch selection
  NB_PROC=$(grep -c ^processor /proc/cpuinfo) && \
  ARCH=$(uname -m); \
  case "$ARCH" in \
    x86_64) MARCH="x86-64-v3"; MTUNE="alderlake"; CFI_FLAGS="-fcf-protection=full" ;; \
    aarch64) MARCH="armv8.2-a+crypto+crc+lse+rdma"; MTUNE="cortex-a55"; CFI_FLAGS="-mbranch-protection=standard" ;; \
  esac; \
  \
  export HARDENING_CFLAGS="-fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 \
    -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} \
    -fno-plt -fno-semantic-interposition -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr \
    -ftrapv -fno-delete-null-pointer-checks -fipa-pta -fno-math-errno -fmerge-all-constants -fomit-frame-pointer" && \
  \
  export OPT_CFLAGS="-O3 -march=${MARCH} -mtune=${MTUNE} -pipe -flto=auto ${HARDENING_CFLAGS}" && \
  export OPT_LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} -flto=auto" && \
  export CC="ccache gcc" CXX="ccache g++"  && \
  \
  echo "Building for $ARCH -> march=$MARCH | mtune=$MTUNE | cfi=$CFI_FLAGS"; \
  \
  wget -O - https://freenginx.org/download/freenginx-${BUILD_VERSION}.tar.gz --tries=3 | tar zxf - -C /tmp && \
  wget -O - https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
  wget -O - https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
  \
  git clone --depth 1 ${BROTLI_URL} /tmp/ngx_brotli && \
  cd /tmp/ngx_brotli && \
  git submodule update --init && \
  \
  # Building brotli library
  cd /tmp/ngx_brotli/deps/brotli && \
  mkdir -p out && cd out && \
  cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_C_FLAGS="$OPT_CFLAGS -fPIC" \
    -DCMAKE_CXX_FLAGS="$OPT_CFLAGS -fPIC" \
    -DCMAKE_EXE_LINKER_FLAGS="$OPT_LDFLAGS" \
    -DCMAKE_INSTALL_PREFIX=./installed \
    .. && \
  cmake --build . --config Release --target brotlienc brotlidec brotlicommon && \
  make install && \
  \
  # Building pcre2
  cd /tmp/pcre2-${PCRE_VERSION} && \
  mkdir -p build && cd build && \
  cmake \
    -DCMAKE_INSTALL_PREFIX=/usr/local/pcre2 \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_STATIC_LIBS=ON \
    -DPCRE2_SUPPORT_JIT=ON \
    -DPCRE2_SUPPORT_UNICODE=ON \
    -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DPCRE2_BUILD_TESTS=OFF \
    -DCMAKE_C_FLAGS="$OPT_CFLAGS -fPIC" \
    -DCMAKE_EXE_LINKER_FLAGS="$OPT_LDFLAGS" \
    .. && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install && \
  \
  git clone --depth 1 ${GEOIP2_URL} /tmp/ngx_geoip2 && \
  mkdir -p /etc/nginx/geoip && \
  wget -O /etc/nginx/geoip/GeoLite2-Country.mmdb \
       ${GEOIP2_BASE_URL}/releases/latest/download/GeoLite2-Country.mmdb && \
  git clone --depth 1 ${HEADERS_MORE_URL} /tmp/ngx_headers_more && \
  \
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
        -DMI_LIBC_MUSL=ON \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_C_FLAGS="$OPT_CFLAGS -fPIC" \
        -DCMAKE_SHARED_LINKER_FLAGS="$OPT_LDFLAGS" \
        ../.. && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install && \
  \
  # Building openssl
  cd /tmp/openssl-${OPENSSL_VERSION} && \  
  ./config \
    --prefix=/usr/local/ssl \
    --openssldir=/usr/local/ssl \
    no-shared \
    enable-quic enable-tfo enable-ktls no-tests \
    -O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fomit-frame-pointer \
    ${HARDENING_CFLAGS} \
    -Wformat-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 \
    -DOPENSSL_TLS_SECURITY_LEVEL=3 ${CFI_FLAGS} \
    -fuse-ld=mold -flto=auto && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install_sw install_ssldirs && \
  \
  # Building zlib-ng
  git clone --depth 1 -b ${ZLIB_NG_VERSION} https://github.com/zlib-ng/zlib-ng.git /tmp/zlib-ng && \
  cd /tmp/zlib-ng && \
  mkdir -p build && cd build && \
  cmake \
    -DCMAKE_INSTALL_PREFIX=/usr/local/zlib-ng \
    -DZLIB_COMPAT=ON \
    -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF \
    -DWITH_OPTIM=ON \
    -DWITH_NEW_STRATEGIES=ON \
    -DCMAKE_C_FLAGS="$OPT_CFLAGS -fPIC" \
    -DCMAKE_EXE_LINKER_FLAGS="$OPT_LDFLAGS" \
    .. && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  make install && \
  ln -sf /usr/local/zlib-ng/include/zlib.h /usr/include/zlib.h && \
  ln -sf /usr/local/zlib-ng/include/zconf.h /usr/include/zconf.h && \
  \
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
    --without-http_memcached_module \
    --without-http_split_clients_module \
    --without-http_ssi_module \
    --without-http_userid_module \
    --with-file-aio \
    --with-threads \
    --add-module=/tmp/ngx_brotli \
    --add-module=/tmp/ngx_geoip2 \
    --add-module=/tmp/ngx_headers_more \
    --with-cc-opt="-I/usr/local/ssl/include -I/usr/local/zlib-ng/include -I/usr/local/pcre2/include $OPT_CFLAGS -fPIE -grecord-gcc-switches -Wformat-security -Wno-error=strict-aliasing -Wno-error=vla-parameter" \
    --with-ld-opt="-L/usr/local/ssl/lib64 -L/usr/local/ssl/lib -L/usr/local/zlib-ng/lib -L/usr/local/pcre2/lib -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib -fuse-ld=mold -Wl,-pie $OPT_LDFLAGS" \
    --with-pcre-jit \
    && \
  PATH="/usr/lib/ccache:${PATH}" make -j $NB_PROC && \
  strip --strip-unneeded objs/nginx && \
  make install

# ==========================================
# Stage 2: Runtime
# ==========================================
FROM alpine:latest AS runtime

LABEL org.opencontainers.image.title="Freenginx Proxy" \
      org.opencontainers.image.description="Freenginx proxy with proper hardening" \
      org.opencontainers.image.version="1.6.0" \
      org.opencontainers.image.source="https://github.com/LordArrin/freenginx-hard"

ENV LD_PRELOAD=/usr/lib/libmimalloc-secure.so \
    MIMALLOC_PURGE_DELAY=120 \
    MIMALLOC_ARENA_EAGER_COMMIT=2

RUN \
  set -euxo pipefail && \
  apk update && \
  apk upgrade --no-cache && \
  runtime_pkgs="ca-certificates tzdata libgcc libstdc++ libatomic libmaxminddb" && \
  apk --no-cache add ${runtime_pkgs} && \
  update-ca-certificates && \
  addgroup -S nginx && \
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
  mkdir -p /tmp/nginx /tmp/logs/nginx /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx /etc/nginx/geoip && \
  chown -R nginx:nginx /tmp/nginx /tmp/logs /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx

COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/share/nginx /usr/share/nginx
COPY --from=builder /usr/local/ssl /usr/local/ssl
COPY --from=builder /usr/lib*/libmimalloc* /usr/lib/

RUN echo "/usr/lib/libmimalloc-secure.so" > /etc/ld.so.preload

RUN ln -sf /usr/local/ssl/bin/openssl /usr/sbin/openssl && \
    ln -sf /usr/local/ssl/bin/c_rehash /usr/sbin/c_rehash

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=3s CMD kill -0 $(cat /tmp/nginx.pid) || exit 1

EXPOSE 80/tcp 443/tcp 443/udp

USER nginx

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]