# Versions
ARG ALPINE_VERSION=3.24
ARG BUILD_VERSION=1.31.5
ARG OPENSSL_VERSION=4.1.0
ARG PCRE_VERSION=10.49
ARG MIMALLOC_VERSION=3.6.1
ARG ZLIB_NG_VERSION=2.3.3
ARG IMAGE_VERSION=1.6.4

# Module sources
ARG BROTLI_URL=https://github.com/wxx9248/ngx_brotli.git
ARG GEOIP2_URL=https://github.com/intechcore/ngx_http_geoip2_module.git
ARG GEOIP2_BASE_URL=https://github.com/mojolabs-id/GeoLite2-Database
ARG HEADERS_MORE_URL=https://github.com/openresty/headers-more-nginx-module.git

# Build tuning
ARG BUILD_JOBS=0
ARG ENABLE_LTO=ON
ARG X86_MARCH=x86-64
ARG X86_MTUNE=generic
ARG X86_CFI_FLAGS=""
ARG ARM_MARCH=armv8-a
ARG ARM_MTUNE=generic
ARG ARM_CFI_FLAGS="-mbranch-protection=standard"

FROM alpine:${ALPINE_VERSION} AS builder

ARG BUILD_VERSION OPENSSL_VERSION PCRE_VERSION MIMALLOC_VERSION ZLIB_NG_VERSION
ARG BROTLI_URL GEOIP2_URL GEOIP2_BASE_URL HEADERS_MORE_URL
ARG BUILD_JOBS ENABLE_LTO
ARG X86_MARCH X86_MTUNE X86_CFI_FLAGS
ARG ARM_MARCH ARM_MTUNE ARM_CFI_FLAGS

SHELL ["/bin/ash", "-euo", "pipefail", "-c"]
WORKDIR /tmp

# Toolchain
RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache \
        build-base linux-headers fortify-headers ccache \
        wget perl git mold cmake libmaxminddb-dev

ENV CCACHE_DIR=/ccache \
    CCACHE_MAXSIZE=2G \
    PATH=/usr/lib/ccache:$PATH

# Shared compile flags -> /tmp/build-env.sh, sourced by every build step
RUN <<'SCRIPT'
set -eu

if [ "$BUILD_JOBS" = "0" ]; then NB_PROC="$(nproc)"; else NB_PROC="$BUILD_JOBS"; fi
if [ "$ENABLE_LTO" = "ON" ]; then LTO_FLAG="-flto=auto"; else LTO_FLAG=""; fi

case "$(uname -m)" in
    x86_64)  MARCH="$X86_MARCH"; MTUNE="$X86_MTUNE"; CFI_FLAGS="$X86_CFI_FLAGS" ;;
    aarch64) MARCH="$ARM_MARCH"; MTUNE="$ARM_MTUNE"; CFI_FLAGS="$ARM_CFI_FLAGS" ;;
    *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

HARDENING_CFLAGS="-fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 \
-Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3 ${CFI_FLAGS} \
-fno-plt -fno-semantic-interposition -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr \
-ftrapv -fno-delete-null-pointer-checks -fipa-pta -fno-math-errno -fmerge-all-constants -fomit-frame-pointer"

cat > /tmp/build-env.sh <<EOF
export NB_PROC="$NB_PROC"
export MARCH="$MARCH" MTUNE="$MTUNE" CFI_FLAGS="$CFI_FLAGS" LTO_FLAG="$LTO_FLAG"
export HARDENING_CFLAGS="$HARDENING_CFLAGS"
export OPT_CFLAGS="-O3 -march=$MARCH -mtune=$MTUNE -pipe $LTO_FLAG $HARDENING_CFLAGS"
export OPT_LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs $CFI_FLAGS $LTO_FLAG"
export CC="ccache gcc" CXX="ccache g++"
EOF

echo "build-env: $(uname -m) march=$MARCH mtune=$MTUNE jobs=$NB_PROC lto='$LTO_FLAG'"
SCRIPT

# PCRE2
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
    wget -O - --tries=3 https://github.com/PCRE2Project/pcre2/releases/download/pcre2-${PCRE_VERSION}/pcre2-${PCRE_VERSION}.tar.gz | tar xzf - -C /tmp && \
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
    make -j "$NB_PROC" && make install

# zlib-ng
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
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
    make -j "$NB_PROC" && make install && \
    ln -sf /usr/local/zlib-ng/include/zlib.h /usr/include/zlib.h && \
    ln -sf /usr/local/zlib-ng/include/zconf.h /usr/include/zconf.h

# Brotli static deps for ngx_brotli
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
    git clone --depth 1 ${BROTLI_URL} /tmp/ngx_brotli && \
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
    cmake --build . --config Release --target brotlienc brotlidec brotlicommon --parallel "$NB_PROC" && \
    make install

# mimalloc
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
    git clone --depth 1 -b v${MIMALLOC_VERSION} https://github.com/microsoft/mimalloc.git /tmp/mimalloc && \
    cd /tmp/mimalloc && \
    mkdir -p out/release && cd out/release && \
    cmake \
        -DCMAKE_BUILD_TYPE=Release \
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
    make -j "$NB_PROC" && make install

# OpenSSL: expensive and bumped often, kept after the cheap libraries
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
    wget -O - --tries=3 https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz | tar xzf - -C /tmp && \
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
    make -j "$NB_PROC" && \
    make install_sw install_ssldirs

# nginx modules
RUN git clone --depth 1 ${GEOIP2_URL} /tmp/ngx_geoip2 && \
    git clone --depth 1 ${HEADERS_MORE_URL} /tmp/ngx_headers_more

# GeoLite2 database (builder-only; not copied to the runtime stage)
RUN mkdir -p /etc/nginx/geoip && \
    wget -O /etc/nginx/geoip/GeoLite2-Country.mmdb \
        ${GEOIP2_BASE_URL}/releases/latest/download/GeoLite2-Country.mmdb

# freenginx source
RUN wget -O - --tries=3 https://freenginx.org/download/freenginx-${BUILD_VERSION}.tar.gz | tar zxf - -C /tmp

# Fingerprinting patches: remove Server header (h1/h2/h3) and error-page footer.
# grep assertions fail the build if upstream changes the patched code.
RUN <<'SCRIPT'
set -eu
cd "/tmp/freenginx-${BUILD_VERSION}"

h1=src/http/ngx_http_header_filter_module.c
h2=src/http/v2/ngx_http_v2_filter_module.c
h3=src/http/v3/ngx_http_v3_filter_module.c
sp=src/http/ngx_http_special_response.c

for f in "$h1" "$h2" "$h3"; do
    grep -q 'r->headers_out.server == NULL' "$f" || \
        { echo "ERROR: pattern not found in $f — update the patch" >&2; exit 1; }
    sed -i 's@r->headers_out.server == NULL@0@g' "$f"
done

# Footer is macro-concatenated: "<hr><center>" NGINX_NAME "</center>".
# Strip all three variants (NGINX_VER / NGINX_VER_BUILD / NGINX_NAME).
grep -Eq '"<hr><center>"[[:space:]]+NGINX_(VER_BUILD|VER|NAME)[[:space:]]+"</center>"' "$sp" || \
    { echo "ERROR: footer pattern not found in $sp" >&2; exit 1; }
sed -E -i 's@"<hr><center>"[[:space:]]+NGINX_(VER_BUILD|VER|NAME)[[:space:]]+"</center>"@@g' "$sp"

if grep -q 'r->headers_out.server == NULL' "$h1" "$h2" "$h3" || grep -q '<hr><center>' "$sp"; then
    echo "ERROR: fingerprinting patches were not applied" >&2
    exit 1
fi
echo "fingerprinting patches: OK"
SCRIPT

# Configure + build
RUN --mount=type=cache,target=/ccache \
    . /tmp/build-env.sh && \
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
    make -j "$NB_PROC"

# Hardening gates: fail the build if a promised protection is missing.
# Symbol gates run on the unstripped binary.
# NOTE: never use `producer | grep -q` here: under pipefail, grep -q exits
# on the first match, the producer dies with SIGPIPE (141) and the gate
# fails even on success. `grep ... >/dev/null` consumes the full input.
RUN --mount=type=cache,target=/ccache <<'SCRIPT'
set -eu
. /tmp/build-env.sh
cd "/tmp/freenginx-${BUILD_VERSION}"
BIN=objs/nginx

fail() { echo "HARDENING GATE FAILED: $*" >&2; exit 1; }

# PIE (full ASLR)
file "$BIN" | grep 'pie executable' >/dev/null || fail "binary is not PIE"

# Full RELRO: GNU_RELRO segment + immediate binding
readelf -lW "$BIN" | grep 'GNU_RELRO' >/dev/null || fail "no GNU_RELRO segment"
readelf -dW "$BIN" | grep 'NOW' >/dev/null || fail "no BIND_NOW (partial RELRO only)"

# Non-executable stack
readelf -lW "$BIN" | grep 'GNU_STACK' >/dev/null || fail "no GNU_STACK segment"
if readelf -lW "$BIN" | grep 'GNU_STACK' | grep 'RWE' >/dev/null; then
    fail "executable stack"
fi

# Stack protector (matches __stack_chk_fail and __stack_chk_fail_local)
readelf -sW "$BIN" | grep '__stack_chk_fail' >/dev/null || fail "stack protector dropped"

# Expected OpenSSL version statically embedded
strings "$BIN" | grep "OpenSSL ${OPENSSL_VERSION}" >/dev/null || fail "OpenSSL ${OPENSSL_VERSION} not embedded"

# zlib-ng instead of stock zlib
strings "$BIN" | grep 'zlib-ng' >/dev/null || fail "zlib-ng signature missing"

# PCRE2 JIT compiled in
readelf -sW "$BIN" | grep 'pcre2_jit_compile' >/dev/null || fail "PCRE2 JIT missing"

# GCC LTO bytecode in our objects (when LTO is enabled)
if [ -n "$LTO_FLAG" ]; then
    readelf -SW objs/src/core/nginx.o | grep '\.gnu\.lto_' >/dev/null || fail "no LTO bytecode in nginx.o"
fi

# CFI instrumentation in our own objects (when CFI flags are set).
# The final-binary note is AND-merged with distro crt objects; Alpine gcc
# is built with --disable-cet, so the note is lost at link time. musl does
# not activate CET at runtime either — gate our objects, report the rest.
if [ -n "$CFI_FLAGS" ]; then
    case "$(uname -m)" in
        x86_64)
            readelf -n objs/src/core/nginx.o | grep 'IBT' >/dev/null || fail "IBT missing in nginx.o"
            readelf -n objs/src/core/nginx.o | grep 'SHSTK' >/dev/null || fail "SHSTK missing in nginx.o"
            readelf -n "$BIN" | grep 'IBT' >/dev/null || \
                echo "NOTE: CET note lost at link time (unmarked distro crt objects)"
            ;;
        aarch64)
            readelf -n objs/src/core/nginx.o | grep 'BTI' >/dev/null || fail "BTI missing in nginx.o"
            readelf -n objs/src/core/nginx.o | grep 'PAC' >/dev/null || fail "PAC missing in nginx.o"
            readelf -n "$BIN" | grep 'BTI' >/dev/null || \
                echo "NOTE: BTI note lost at link time (unmarked OpenSSL asm / distro crt)"
            ;;
    esac
fi

# FORTIFY functional probe: an out-of-bounds copy into a known-size heap
# buffer must trap. Alpine uses fortify-headers (inline checks + ud2),
# so there are no __*_chk symbols to grep for.
cat > /tmp/fortify-probe.c <<'EOF'
#include <stdlib.h>
#include <string.h>
int main(void) {
    char *b = malloc(4);
    volatile char sink;
    if (!b) return 2;
    memcpy(b, "aaaaaaaa", 8);
    sink = b[0];
    (void)sink;
    return 0;
}
EOF
cc $OPT_CFLAGS -o /tmp/fortify-probe /tmp/fortify-probe.c
if /tmp/fortify-probe; then
    fail "FORTIFY probe survived an out-of-bounds copy"
fi
echo "hardening gates: OK"

strip --strip-unneeded "$BIN"
make install
/usr/sbin/nginx -V
ccache -s
SCRIPT

# =============================================================================
# Runtime
# =============================================================================
FROM alpine:${ALPINE_VERSION} AS runtime

ARG IMAGE_VERSION

LABEL org.opencontainers.image.title="Freenginx Proxy" \
      org.opencontainers.image.description="Freenginx proxy with proper hardening" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.source="https://github.com/LordArrin/freenginx-hard"

ENV LD_PRELOAD=/usr/lib/libmimalloc-secure.so \
    MIMALLOC_PURGE_DELAY=120 \
    MIMALLOC_ARENA_EAGER_COMMIT=2

RUN apk update && apk upgrade --no-cache && \
    apk add --no-cache ca-certificates tzdata libgcc libstdc++ libatomic libmaxminddb && \
    update-ca-certificates && \
    addgroup -S nginx && \
    adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx && \
    mkdir -p /tmp/nginx /tmp/logs/nginx /tmp/client_temp /tmp/proxy_temp \
             /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx /etc/nginx/geoip && \
    chown -R nginx:nginx /tmp/nginx /tmp/logs /tmp/client_temp /tmp/proxy_temp \
             /tmp/fastcgi_temp /tmp/uwsgi_temp /tmp/scgi_temp /var/cache/nginx

COPY --from=builder /usr/sbin/nginx /usr/sbin/nginx
COPY --from=builder /usr/share/nginx /usr/share/nginx
COPY --from=builder /usr/local/ssl /usr/local/ssl
COPY --from=builder /tmp/mimalloc-install/lib*/libmimalloc* /usr/lib/

# Fail on a broken mimalloc preload instead of silently running without it
RUN MIMALLOC_LIB=$(find /usr/lib -maxdepth 1 \( -name 'libmimalloc*.so*' -type f -o -type l \) | head -n1) && \
    test -n "$MIMALLOC_LIB" && test -e "$MIMALLOC_LIB" && \
    ln -sf "$MIMALLOC_LIB" /usr/lib/libmimalloc-secure.so && \
    echo "/usr/lib/libmimalloc-secure.so" > /etc/ld.so.preload

RUN ln -sf /usr/local/ssl/bin/openssl /usr/sbin/openssl && \
    ln -sf /usr/local/ssl/bin/c_rehash /usr/sbin/c_rehash

COPY files/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD kill -0 $(cat /tmp/nginx.pid) 2>/dev/null || exit 1

EXPOSE 80/tcp 443/tcp 443/udp

USER nginx

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]