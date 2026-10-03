ARG ALPINE_VERSION=3.24

ARG BUILD_VERSION=1.31.4
ARG OPENSSL_VERSION=4.0.3
ARG PCRE_VERSION=10.49
ARG MIMALLOC_VERSION=2.5.2
ARG ZLIB_NG_VERSION=2.3.3
# Pin third-party module forks by tag/SHA instead of mutable default branches:
# with --depth 1 on a moving branch every weekly CI build produced a new layer
# and invalidated the whole cache chain (OpenSSL rebuild ~1h).
# Set e.g. --build-arg BROTLI_REF=<commit-sha> to get reproducible, cache-stable layers.
ARG BROTLI_URL=https://github.com/wxx9248/ngx_brotli.git
ARG BROTLI_REF=master
ARG GEOIP2_URL=https://github.com/kraloveckey/nginx-geoip2.git
ARG GEOIP2_REF=master
ARG GEOIP2_BASE_URL=https://github.com/mojolabs-id/GeoLite2-Database
ARG HEADERS_MORE_URL=https://github.com/openresty/headers-more-nginx-module.git
ARG HEADERS_MORE_REF=master

ARG X86_MARCH=x86-64
ARG X86_MTUNE=generic
ARG X86_CFI_FLAGS=""

ARG ARM_MARCH=armv8-a
ARG ARM_MTUNE=generic
ARG ARM_CFI_FLAGS="-mbranch-protection=standard"

ARG BUILD_JOBS=0
ARG ENABLE_LTO=ON

# ---------------------------------------------------------------------------
# Common builder base: toolchain + hardened flags shared by all stages below.
# Only ALPINE_VERSION / compiler-flag ARGs invalidate this stage — NOT
# BUILD_VERSION, so a freenginx bump no longer rebuilds OpenSSL/PCRE2/etc.
# ---------------------------------------------------------------------------
FROM alpine:${ALPINE_VERSION} AS builder-base

# ccache: keep the cache in a fixed dir (per-stage env does not share $HOME state)
ENV CCACHE_DIR=/tmp/ccache \
    PATH="/usr/lib/ccache:${PATH}"

RUN \
  set -euxo pipefail && \
  apk update && \
  apk upgrade --no-cache && \
  build_pkgs="build-base linux-headers fortify-headers ccache wget curl perl git mold cmake libmaxminddb-dev" && \
  apk --no-cache add --virtual .build-deps ${build_pkgs} && \
  rm -rf /var/cache/apk/*

ARG X86_MARCH
ARG X86_MTUNE
ARG X86_CFI_FLAGS
ARG ARM_MARCH
ARG ARM_MTUNE
ARG ARM_CFI_FLAGS
ARG ENABLE_LTO
ARG BUILD_JOBS

# Resolve per-arch flags and job count ONCE at configure time. The values are
# baked into the generated file as literal strings, so downstream stages only
# read them — no recompilation logic is duplicated across stages.
# Cache invalidation scope of this layer: ALPINE_VERSION + the ARGs above.
# Crucially it does NOT depend on BUILD_VERSION, so a freenginx bump never
# rebuilds OpenSSL/PCRE2/mimalloc/zlib-ng layers.
RUN \
  set -euxo pipefail && \
  if [ "$ENABLE_LTO" = "ON" ]; then LTO_FLAG="-flto=auto"; else LTO_FLAG=""; fi && \
  if [ "${BUILD_JOBS:-0}" = "0" ]; then NB_PROC=$(grep -c ^processor /proc/cpuinfo); else NB_PROC="$BUILD_JOBS"; fi && \
  ARCH=$(uname -m); \
  case "$ARCH" in \
    x86_64) MARCH="${X86_MARCH}"; MTUNE="${X86_MTUNE}"; CFI_FLAGS="${X86_CFI_FLAGS}" ;; \
    aarch64) MARCH="${ARM_MARCH}"; MTUNE="${ARM_MTUNE}"; CFI_FLAGS="${ARM_CFI_FLAGS}" ;; \
  esac; \
  HARDENING_CFLAGS="-fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} -fno-plt -fno-semantic-interposition -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr -ftrapv -fno-delete-null-pointer-checks -fipa-pta -fno-math-errno -fmerge-all-constants -fomit-frame-pointer"; \
  OPT_CFLAGS="-O3 -march=${MARCH} -mtune=${MTUNE} -pipe ${LTO_FLAG} ${HARDENING_CFLAGS}"; \
  OPT_LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs ${CFI_FLAGS} ${LTO_FLAG}"; \
  { \
    echo 'export CC="ccache gcc"'; \
    echo 'export CXX="ccache g++"'; \
    printf 'export ARCH="%s"\n'       "$ARCH"; \
    printf 'export MARCH="%s"\n'      "$MARCH"; \
    printf 'export MTUNE="%s"\n'      "$MTUNE"; \
    printf 'export CFI_FLAGS="%s"\n'  "$CFI_FLAGS"; \
    printf 'export LTO_FLAG="%s"\n'   "$LTO_FLAG"; \
    printf 'export NB_PROC="%s"\n'    "$NB_PROC"; \
    printf 'export HARDENING_CFLAGS="%s"\n' "$HARDENING_CFLAGS"; \
    printf 'export OPT_CFLAGS="%s"\n' "$OPT_CFLAGS"; \
    printf 'export OPT_LDFLAGS="%s"\n' "$OPT_LDFLAGS"; \
  } > /opt/build-env.sh && \
  cat /opt/build-env.sh

# ---------------------------------------------------------------------------
# Stage: openssl (the ~1h component — now cached independently of everything)
# Invalidated only by: OPENSSL_VERSION, compiler-flag ARGs, ALPINE_VERSION.
# ---------------------------------------------------------------------------
FROM builder-base AS openssl

ARG OPENSSL_VERSION

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
  wget -O - https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
  cd /tmp/openssl-${OPENSSL_VERSION} && \
  LDFLAGS="$OPT_LDFLAGS" ./config \
    --prefix=/usr/local/ssl \
    --openssldir=/usr/local/ssl \
    no-shared \
    enable-quic enable-tfo enable-ktls no-tests \
    -O3 -march=${MARCH} -mtune=${MTUNE} -pipe -fomit-frame-pointer \
    ${HARDENING_CFLAGS} \
    -Wformat-security -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 \
    -DOPENSSL_TLS_SECURITY_LEVEL=3 ${CFI_FLAGS} \
    -fuse-ld=mold ${LTO_FLAG} && \
  make -j $NB_PROC && \
  make install_sw install_ssldirs

# ---------------------------------------------------------------------------
# Stage: pcre2
# ---------------------------------------------------------------------------
FROM builder-base AS pcre2

ARG PCRE_VERSION

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
  wget -O - https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz --tries=3 | tar xzf - -C /tmp && \
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
  make -j $NB_PROC && \
  make install

# ---------------------------------------------------------------------------
# Stage: brotli (deps of ngx_brotli, built static)
# ---------------------------------------------------------------------------
FROM builder-base AS brotli

ARG BROTLI_URL
ARG BROTLI_REF

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
  git clone --depth 1 --branch "${BROTLI_REF}" ${BROTLI_URL} /tmp/ngx_brotli && \
  cd /tmp/ngx_brotli && \
  git submodule update --init && \
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
  cmake --build . --config Release --target brotlienc brotlidec brotlicommon --parallel $NB_PROC && \
  make install

# ---------------------------------------------------------------------------
# Stage: mimalloc
# ---------------------------------------------------------------------------
FROM builder-base AS mimalloc

ARG MIMALLOC_VERSION

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
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
        -DCMAKE_INSTALL_PREFIX=/tmp/mimalloc-install \
        -DCMAKE_C_FLAGS="$OPT_CFLAGS -fPIC" \
        -DCMAKE_SHARED_LINKER_FLAGS="$OPT_LDFLAGS" \
        ../.. && \
  make -j $NB_PROC && \
  make install

# ---------------------------------------------------------------------------
# Stage: zlib-ng
# ---------------------------------------------------------------------------
FROM builder-base AS zlib-ng

ARG ZLIB_NG_VERSION

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
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
  make -j $NB_PROC && \
  make install && \
  ln -sf /usr/local/zlib-ng/include/zlib.h /usr/include/zlib.h && \
  ln -sf /usr/local/zlib-ng/include/zconf.h /usr/include/zconf.h

# ---------------------------------------------------------------------------
# Stage: modules — source-only clones + GeoLite2 DB download.
# No compilation here: cheap, independent layers. A weekly drift of a fork's
# master branch now invalidates ONLY this small layer + the nginx link step,
# never OpenSSL/PCRE2/mimalloc/zlib-ng.
# ---------------------------------------------------------------------------
FROM builder-base AS modules

ARG GEOIP2_URL
ARG GEOIP2_REF
ARG GEOIP2_BASE_URL
ARG HEADERS_MORE_URL
ARG HEADERS_MORE_REF

RUN \
  set -euxo pipefail && \
  cd /tmp && \
  git clone --depth 1 --branch "${GEOIP2_REF}" ${GEOIP2_URL} /tmp/ngx_geoip2 && \
  git clone --depth 1 --branch "${HEADERS_MORE_REF}" ${HEADERS_MORE_URL} /tmp/ngx_headers_more && \
  mkdir -p /etc/nginx/geoip && \
  wget -O /etc/nginx/geoip/GeoLite2-Country.mmdb \
       ${GEOIP2_BASE_URL}/releases/latest/download/GeoLite2-Country.mmdb

# ---------------------------------------------------------------------------
# Stage: freenginx — final assembly. Depends on all component stages above;
# COPY --from pulls their artifacts WITHOUT rebuilding them when only
# BUILD_VERSION changes.
# ---------------------------------------------------------------------------
FROM builder-base AS freenginx

COPY --from=openssl     /usr/local/ssl      /usr/local/ssl
COPY --from=pcre2       /usr/local/pcre2    /usr/local/pcre2
COPY --from=zlib-ng     /usr/local/zlib-ng  /usr/local/zlib-ng
COPY --from=brotli      /tmp/ngx_brotli/deps/brotli/out/installed /usr/local/brotli
COPY --from=brotli      /tmp/ngx_brotli /tmp/ngx_brotli
COPY --from=mimalloc    /tmp/mimalloc-install /tmp/mimalloc-install
COPY --from=modules     /tmp/ngx_geoip2 /tmp/ngx_geoip2
COPY --from=modules     /tmp/ngx_headers_more /tmp/ngx_headers_more
COPY --from=modules     /etc/nginx/geoip /etc/nginx/geoip

ARG BUILD_VERSION

RUN \
  set -euxo pipefail && \
  . /opt/build-env.sh && \
  cd /tmp && \
  wget -O - https://freenginx.org/download/freenginx-${BUILD_VERSION}.tar.gz --tries=3 | tar zxf - -C /tmp && \
  \
  # freenginx's configure only appends --with-cc-opt/--with-ld-opt to CFLAGS/LDFLAGS,
  # so seed them from the shared build env (same semantics as the old monolithic RUN)
  export CFLAGS="$OPT_CFLAGS" LDFLAGS="$OPT_LDFLAGS" && \
  \
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
    --with-cc-opt="-I/usr/local/ssl/include -I/usr/local/zlib-ng/include -I/usr/local/pcre2/include -I/usr/local/brotli/include $OPT_CFLAGS -fPIE -grecord-gcc-switches -Wformat-security -Wno-error=strict-aliasing -Wno-error=vla-parameter" \
    --with-ld-opt="-L/usr/local/ssl/lib64 -L/usr/local/ssl/lib -L/usr/local/zlib-ng/lib -L/usr/local/pcre2/lib -L/usr/local/brotli/lib -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib -fuse-ld=mold -Wl,-pie $OPT_LDFLAGS" \
    --with-pcre-jit \
    && \
  make -j $NB_PROC && \
  strip --strip-unneeded objs/nginx && \
  make install

# ---------------------------------------------------------------------------
# Stage: artifacts — single flat source for the runtime image, so the runtime
# COPY layers are invalidated only when a component actually changed.
# ---------------------------------------------------------------------------
FROM freenginx AS artifacts

RUN set -euxo pipefail && \
    mkdir -p /out && \
    cp -a /usr/sbin/nginx /out/nginx && \
    cp -a /usr/share/nginx /out/nginx-share && \
    cp -a /usr/local/ssl /out/ssl && \
    find /tmp/mimalloc-install/lib* \( -name 'libmimalloc*.so*' \) -type f -exec cp -a {} /out/ \;

FROM alpine:${ALPINE_VERSION} AS runtime

LABEL org.opencontainers.image.title="Freenginx Proxy" \
      org.opencontainers.image.description="Freenginx proxy with proper hardening" \
      org.opencontainers.image.version="1.6.3" \
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
  rm -rf /var/cache/apk/* && \
  update-ca-certificates && \
  addgroup -S nginx && \
  adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
  mkdir -p /tmp/nginx /tmp/logs/nginx /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx /etc/nginx/geoip && \
  chown -R nginx:nginx /tmp/nginx /tmp/logs /tmp/client_temp /tmp/proxy_temp /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx

COPY --from=artifacts /out/nginx        /usr/sbin/nginx
COPY --from=artifacts /out/nginx-share  /usr/share/nginx
COPY --from=artifacts /out/ssl          /usr/local/ssl
COPY --from=artifacts /out/             /tmp/mimalloc-out/
RUN set -euxo pipefail && \
    mkdir -p /usr/lib && \
    find /tmp/mimalloc-out -maxdepth 1 -name 'libmimalloc*.so*' -type f -exec cp -a {} /usr/lib/ \; && \
    rm -rf /tmp/mimalloc-out

RUN MIMALLOC_LIB=$(find /usr/lib -maxdepth 1 \( -name 'libmimalloc*.so*' -type f -o -type l \) | head -n1) && \
    ln -sf "$MIMALLOC_LIB" /usr/lib/libmimalloc-secure.so && \
    echo "/usr/lib/libmimalloc-secure.so" > /etc/ld.so.preload

RUN ln -sf /usr/local/ssl/bin/openssl /usr/sbin/openssl && \
    ln -sf /usr/local/ssl/bin/c_rehash /usr/sbin/c_rehash

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=3s CMD kill -0 $(cat /tmp/nginx.pid) || exit 1

EXPOSE 80/tcp 443/tcp 443/udp

USER nginx

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
