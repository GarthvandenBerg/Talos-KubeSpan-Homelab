One you have created the container image and created the tar file, upload the tar.gz to container images in Proxmox.

Create container and login as "root" - not real root because root is mapped to UUID 10000

```
apk add --no-cache su-exec
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy
```

Create /etc/local.d/caddy.start:

```
vi /etc/local.d/caddy.start
```
```
#!/bin/sh
if [ -f /etc/cloudflare.cred ]; then
    export $(grep -v '^#' /etc/cloudflare.cred | xargs)
fi
# Start Caddy in the background as the 'caddy' user
su-exec caddy:caddy /usr/bin/caddy run --config /etc/caddy/Caddyfile > /var/log/caddy/caddy.log 2>&1 &
```
Make it executable and enable the local boot service:
```
chmod +x /etc/local.d/caddy.start
rc-update add local default
```
Now, whenever the container starts:
OpenRC runs the local boot script.
su-exec drops privileges to the caddy user.
Caddy runs as caddy in the background, logging to /var/log/caddy/caddy.log.


Create your Cloudflare Credentials File:

```
vi /etc/cloudflare.cred
```
Add your API token in the file:
```
CLOUDFLARE_API_TOKEN=your_secret_api_token_here
```

```
chmod 600 /etc/cloudflare.cred
chown caddy:caddy /etc/cloudflare.cred
```


Then setup keepalived for VIP for Caddy Main:
```
mkdir -p /etc/keepalived
vi /etc/keepalived/keepalived.conf
```
```
vrrp_script check_caddy {
    script "pidof caddy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state MASTER
    interface eth0
    virtual_router_id 51
    priority 101
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass CaddyHA2026Secret
    }

    virtual_ipaddress {
        192.168.70.244/24
    }

    track_script {
        check_caddy
    }
}
```

```
rc-update add keepalived default
service keepalived start
```

then for the other caddy server:
```
mkdir -p /etc/keepalived
vi /etc/keepalived/keepalived.conf
```
```
vrrp_script check_caddy {
    script "pidof caddy"
    interval 2
    weight 2
}

vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 100
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass CaddyHA2026Secret
    }

    virtual_ipaddress {
        192.168.70.244/24
    }

    track_script {
        check_caddy
    }
}
```

```
rc-update add keepalived default
service keepalived start
```
