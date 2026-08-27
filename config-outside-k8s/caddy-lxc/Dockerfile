# Build image for step 2: Build Caddy with Cloudflare DNS plugin
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddy-dns/cloudflare

# Step 2: Create minimalist runtime rootfs
FROM alpine:3.19
RUN apk add --no-cache keepalived libcap ca-certificates tzdata openrc \
    && addgroup -S caddy \
    && adduser -D -S -h /var/lib/caddy -s /sbin/nologin -G caddy caddy \
    && mkdir -p /etc/caddy /var/lib/caddy \
    && chown -R caddy:caddy /etc/caddy /var/lib/caddy

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
RUN setcap 'cap_net_bind_service=+ep' /usr/bin/caddy

# run as non-root user inside the container
USER caddy
CMD ["/usr/bin/caddy", "run", "--config", "/etc/caddy/Caddyfile"]
