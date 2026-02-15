# Security Tools (Optional)

This blueprint ships with a hardened baseline (SSH, UFW, auditd, unattended-upgrades, Docker hardening). For higher assurance, you can add classic host security tools and scheduled scans.

## What You Get

If you install the optional tooling, you'll have:

- **AIDE**: file integrity monitoring (detects unexpected file changes)
- **Lynis**: weekly hardening/security audit (score + warnings)
- **rkhunter**: weekly rootkit scan (heuristic, can produce false positives)
- **debsums**: verifies installed package files against checksums
- **acct**: process accounting (tracks executed commands)
- **needrestart**: applies security updates faster by restarting affected services
- **pwquality**: stronger local password policy (useful for console recovery)

## Install

Run on the VM:

```bash
sudo ./scripts/security/setup-security-tools.sh
```

This will:

- Install packages via `apt`
- Copy scan scripts to `/opt/scripts/`
- Install cron schedule at `/etc/cron.d/security-scans`
- Install logrotate rules at `/etc/logrotate.d/security-tools`
- Store logs under `/var/log/hosting-blueprint/security/`

## Alerting (Optional)

By default, scan scripts log locally. To get alerts, create:

`/etc/hosting-blueprint/alerting.env`

```bash
ALERT_WEBHOOK_URL="https://ntfy.sh/<your-topic>"
# ALERT_EMAIL="you@example.com"   # requires a working `mail` setup
```

Notes:

- Webhook is recommended for clean UX (works well with `ntfy`).
- Email alerting depends on MTA/SMTP configuration and is intentionally not enabled automatically.

## Run Manually

```bash
sudo /opt/scripts/hosting-aide-check.sh
sudo /opt/scripts/hosting-rkhunter-check.sh
sudo /opt/scripts/hosting-lynis-audit.sh
sudo /opt/scripts/hosting-debsums-check.sh
```

## Review Logs

```bash
ls -la /var/log/hosting-blueprint/security/
tail -n 200 /var/log/hosting-blueprint/security/aide-check.log
tail -n 200 /var/log/hosting-blueprint/security/lynis-audit.log
tail -n 200 /var/log/hosting-blueprint/security/rkhunter-check.log
tail -n 200 /var/log/hosting-blueprint/security/debsums-check.log
```

## Operational Guidance

- Expect **some false positives** from `rkhunter` and sometimes `Lynis` suggestions.
- Treat alerts as **triage signals**, not proof of compromise.
- If you run these on production, take an initial snapshot before enabling scans and immutability features.

