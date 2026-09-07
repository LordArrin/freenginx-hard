# freenginx-hard

This is a custom hardened build primarily for my personal use case

It includes freenginx with latest zlib-ng, mimalloc, PCRE2, openssl. 

```
nginx version: freenginx/<latest>
built by gcc <alpinelatest> (Alpine <alpinelatest>)
built with OpenSSL <latest>
TLS SNI support enabled
configure arguments: --prefix=/usr/share/nginx --sbin-path=/usr/sbin/nginx --conf-path=/tmp/nginx/nginx.conf
--error-log-path=/tmp/logs/nginx/error.log --http-log-path=/tmp/logs/nginx/access.log --pid-path=/tmp/nginx.pid
--lock-path=/tmp/nginx.lock --http-client-body-temp-path=/tmp/client_temp --http-proxy-temp-path=/tmp/proxy_temp
--http-fastcgi-temp-path=/tmp/fastcgi_temp --http-uwsgi-temp-path=/tmp/uwsgi_temp --http-scgi-temp-path=/tmp/scgi_temp
--with-compat --with-http_auth_request_module --with-http_gunzip_module --with-http_gzip_static_module
--with-http_realip_module --with-http_secure_link_module --with-http_slice_module --with-http_ssl_module
--with-http_sub_module --with-http_v2_module --with-http_v3_module --with-stream --with-stream_realip_module
--with-stream_ssl_module --with-stream_ssl_preread_module --without-http_autoindex_module --without-http_browser_module
--without-http_empty_gif_module --without-http_memcached_module --without-http_split_clients_module
--without-http_ssi_module --without-http_userid_module --with-file-aio --with-threads --add-module=/tmp/ngx_brotli
--add-module=/tmp/ngx_geoip2 --add-module=/tmp/ngx_headers_more --with-cc-opt='-I/usr/local/ssl/include
-I/usr/local/zlib-ng/include -I/usr/local/pcre2/include -O3 -march=x86-64-v3 -mtune=alderlake -pipe -flto=auto
-fstack-protector-strong -fstack-clash-protection --param=ssp-buffer-size=4 -Wp,-U_FORTIFY_SOURCE,-D_FORTIFY_SOURCE=3
-fcf-protection=full -fno-plt -fno-semantic-interposition -ftrivial-auto-var-init=zero -fzero-call-used-regs=used-gpr
-ftrapv -fno-delete-null-pointer-checks -fipa-pta -fno-math-errno -fmerge-all-constants -fPIE -grecord-gcc-switches
-Wformat-security -Wno-error=strict-aliasing -Wno-error=vla-parameter -fomit-frame-pointer'
--with-ld-opt='-L/usr/local/ssl/lib64 -L/usr/local/ssl/lib -L/usr/local/zlib-ng/lib
-L/usr/local/pcre2/lib -Wl,-rpath,/usr/local/ssl/lib64 -Wl,-rpath,/usr/local/ssl/lib
-fuse-ld=mold -Wl,-pie -Wl,-z,relro -Wl,-z,now -Wl,-z,noexecstack -Wl,-z,defs -fcf-protection=full
-flto=auto' --with-pcre-jit
```

## Docker Images

Hardened Freenginx images are built weekly with Brotli, GeoIP2, headers-more modules, and full security hardening. Published to GitHub Container Registry.

### Available Tags

#### Multi-Architecture (amd64 + arm64)

| Tag | x86 `-march` | ARM `-march` | Tuning | Use Case |
|-----|--------------|--------------|--------|----------|
| `latest` | `x86-64` | `armv8-a` | generic | Maximum compatibility |
| `latest-modern` | `x86-64-v3` | `armv8.2-a` + crypto/crc/lse/rdma | generic | Modern servers, universal |

#### Architecture-Specific

| Tag | Architecture | `-march` | `-mtune` | Target Hardware |
|-----|--------------|----------|----------|-----------------|
| `latest-a53` | arm64 | `armv8-a+crc` | `cortex-a53` | Raspberry Pi 3, low-end SBC |
| `latest-a72` | arm64 | `armv8-a+crypto+crc` | `cortex-a72` | Raspberry Pi 4, mid-range ARM |
| `latest-modern-alderlake` | amd64 | `x86-64-v3` | `alderlake` | Intel 12th-14th gen |
| `latest-modern-a55` | arm64 | `armv8.2-a` + crypto/crc/lse/rdma | `cortex-a55` | Modern ARM SoC (Ampere, Graviton3+) |

### Quick Start

```bash
# Generic server
docker run -d --name nginx -p 80:80 -p 443:443 ghcr.io/lordarrin/freenginx-hard:latest

# Raspberry Pi 4
docker run -d --name nginx -p 80:80 -p 443:443 ghcr.io/lordarrin/freenginx-hard:latest-a72

# Modern Intel/AMD server
docker run -d --name nginx -p 80:80 -p 443:443 ghcr.io/lordarrin/freenginx-hard:latest-modern

# Intel 12-14 gen server
docker run -d --name nginx -p 80:80 -p 443:443 ghcr.io/lordarrin/freenginx-hard:latest-modern-alderlake
```

### How to Choose

**Start with `latest-modern`** unless you have specific hardware:
- Works on most modern servers (2015 or later)
- Balanced performance and compatibility
- Multi-arch: auto-selects correct binary on amd64 and arm64

**Use architecture-specific tags** for maximum performance:
- `latest-a53` / `latest-a72`: [random fruit] Pi users get 10-20% throughput gain
- `latest-modern-alderlake`: Intel 12-14th gen get optimal scheduling
- `latest-modern-a55`: Ampere Altra, AWS Graviton3/4, modern ARM SoCs

**Use `latest`** for:
- Legacy hardware or unknown VPS CPU
- Mixed-architecture clusters
- Maximum portability

### Security & Updates

- **Weekly rebuilds** every Sunday at 03:00 UTC with latest security patches
- **Hardening applied**: RELRO, PIE, stack protector, CFI, FORTIFY_SOURCE=3, LTO
- **Mimalloc** allocator preloaded for improved memory efficiency
- **Date-tagged** variants available for reproducible deployments (e.g., `2026-09-07-a72`)

### Included Modules

- `ngx_brotli` — Brotli compression
- `ngx_geoip2` — GeoIP2 database support
- `headers-more-nginx-module` — Custom header manipulation
- HTTP/2, HTTP/3 (QUIC), TLS 1.3, KTLS, TFO support

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
