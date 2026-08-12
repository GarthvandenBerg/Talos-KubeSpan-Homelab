# Stage 1: Build Caddy with Cloudflare DNS plugin
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

# Stage 2: Create minimalist runtime rootfs
FROM alpine:3.19
RUN apk add --no-cache keepalived libcap ca-certificates
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN setcap 'cap_net_bind_service=+ep' /usr/bin/caddy
