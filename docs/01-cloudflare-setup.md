# Cloudflare Setup Guide

Complete guide for configuring Cloudflare for this blueprint.

---

## Overview

This blueprint uses Cloudflare's free tier for:
- **SSL/TLS** - HTTPS encryption (Full mode recommended)
- **CDN** - Content delivery and caching
- **DDoS Protection** - Free DDoS mitigation
- **WAF** - Web Application Firewall
- **Zero Trust Tunnel** - Encrypted tunnel for SSH and apps

---

## DNS Configuration

### 1. Add Domain to Cloudflare

1. Sign up at [cloudflare.com](https://cloudflare.com)
2. Click "Add Site"
3. Enter your domain name
4. Select Free plan
5. Cloudflare scans existing DNS records

### 2. Update Nameservers

At your domain registrar, change nameservers to Cloudflare's:
```
nameserver1.cloudflare.com
nameserver2.cloudflare.com
```

Wait 10-60 minutes for propagation.

### 3. Verify Active

Cloudflare Dashboard will show "Active" when nameservers are updated.

---

## SSL/TLS Configuration

### Encryption Mode: Full

**Dashboard:** SSL/TLS → Overview

Set encryption mode to **Full**.

**Why Full?**
- Avoids "Flexible" downgrade footguns if you ever expose an origin IP later
- Works fine with Tunnel (Cloudflare Tunnel is already encrypted; Caddy can remain HTTP on localhost)

### Additional Settings

**Enable these:**
- ✅ TLS 1.3
- ✅ Automatic HTTPS Rewrites
- ✅ Always Use HTTPS
- ✅ Opportunistic Encryption

**Set minimum TLS version:** 1.2

### Edge Certificates

**Dashboard:** SSL/TLS → Edge Certificates

Create wildcard certificate:
- `*.yourdomain.com`
- `yourdomain.com`

**Important:** Free tier doesn't support multi-level subdomains.
- ❌ `something.subdomain.domain.com`
- ✅ `staging-app.domain.com`
- ✅ `app.domain.com`

---

## Cloudflare Tunnel Setup

For complete tunnel setup, see: **[../infra/cloudflared/tunnel-setup.md](../infra/cloudflared/tunnel-setup.md)**

### Quick Summary

1. **Install cloudflared:**
   ```bash
   sudo ./scripts/install-cloudflared.sh
   ```

2. **Authenticate:**
   ```bash
   cloudflared tunnel login
   ```

3. **Create tunnel:**
   ```bash
   cloudflared tunnel create production-tunnel
   # Save the UUID!
   ```

4. **Configure:**
   ```bash
   sudo cp infra/cloudflared/config.yml.example /etc/cloudflared/config.yml
   sudo nano /etc/cloudflared/config.yml
   # Replace YOUR_TUNNEL_UUID and yourdomain.com
   ```

5. **Route DNS:**
   ```bash
   cloudflared tunnel route dns production-tunnel ssh.yourdomain.com
   ```

6. **Start service:**
   ```bash
   sudo cloudflared service install
   sudo systemctl enable --now cloudflared
   ```

---

## DNS Records (Auto-Created)

After tunnel setup, these records are created automatically:

| Type | Name | Value | Proxy |
|------|------|-------|-------|
| CNAME | ssh | `<UUID>.cfargotunnel.com` | Proxied |
| CNAME | * (optional) | `<UUID>.cfargotunnel.com` | Proxied |

All traffic to `*.yourdomain.com` routes through Cloudflare → Tunnel → Caddy → Apps.

---

## Security Features (Free Tier)

### DDoS Protection
Automatic - no configuration needed.

### WAF (Web Application Firewall)
**Dashboard:** Security → WAF

Default rules enabled:
- SQL injection protection
- XSS protection
- Common exploits blocked

### Rate Limiting (Optional)
**Dashboard:** Security → WAF → Rate limiting rules

Create rules to limit requests:
- Per IP address
- Per URL path
- Per country

### Bot Protection
**Dashboard:** Security → Bots

Enabled by default:
- Blocks known bad bots
- Challenges suspicious traffic

---

## Performance Features

### Caching
**Dashboard:** Caching → Configuration

Default caching rules apply:
- Static assets cached automatically
- HTML pages not cached by default

### Auto Minify
**Dashboard:** Speed → Optimization

Enable:
- ✅ JavaScript
- ✅ CSS
- ✅ HTML

### Brotli Compression
Enabled automatically for all traffic.

---

## Troubleshooting

### SSL Certificate Errors

**Issue:** "Your connection is not private"

**Solution:**
1. Check SSL/TLS mode (should be Full)
2. Wait 1-2 minutes for settings to propagate
3. Clear browser cache

### 502 Bad Gateway

**Issue:** Cloudflare shows 502 error

**Check:**
1. Tunnel running: `sudo systemctl status cloudflared`
2. Caddy running: `sudo docker compose ps` (in infra/reverse-proxy)
3. App running: `sudo docker ps`
4. Tunnel logs: `sudo journalctl -u cloudflared -f`

### DNS Not Resolving

**Issue:** Domain doesn't resolve

**Check:**
1. Nameservers updated at registrar
2. DNS records exist in Cloudflare dashboard
3. Orange cloud (proxy) enabled on records
4. Wait 5-10 minutes for DNS propagation

### Tunnel Disconnects

**Issue:** Tunnel keeps disconnecting

**Check:**
1. Firewall allows outbound 443, 7844: `sudo ufw status`
2. Config file correct: `sudo nano /etc/cloudflared/config.yml`
3. Credentials file exists: `sudo ls -la /etc/cloudflared/*.json`

---

## Best Practices

✅ **Use Full SSL/TLS** - Recommended default (Tunnel still uses localhost HTTP)
✅ **Enable Always Use HTTPS** - Force encryption
✅ **Enable rate limiting** - Protect against abuse
✅ **Monitor tunnel status** - Check daily
✅ **Keep cloudflared updated** - Security patches

---

## References

- [Cloudflare Tunnel Docs](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [SSL/TLS Guide](https://developers.cloudflare.com/ssl/)
- [WAF Documentation](https://developers.cloudflare.com/waf/)
- [Complete Tunnel Setup](../infra/cloudflared/tunnel-setup.md)
