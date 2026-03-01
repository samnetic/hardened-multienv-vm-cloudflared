# Architecture Diagrams

Visual representations of the hosting-blueprint architecture.

## Network Flow

```mermaid
graph TB
    subgraph Internet
        User[User / Browser]
        CI[GitHub Actions CI]
        CrowdSec[CrowdSec Hub]
    end

    subgraph Cloudflare
        CF[Cloudflare Edge]
        WAF[WAF Rules]
        Access[Zero Trust Access]
        Tunnel[Argo Tunnel<br/>Post-Quantum QUIC]
    end

    subgraph VM["Hardened VM (Ubuntu 24.04)"]
        subgraph Host["Host OS"]
            UFW[UFW Firewall<br/>deny all incoming]
            SSH[sshd :22<br/>key-only]
            Cloudflared[cloudflared<br/>tunnel daemon]
        end

        subgraph Docker["Docker (127.0.0.1 binding)"]
            Caddy[Caddy Reverse Proxy<br/>:80 localhost]

            subgraph Apps["Application Networks"]
                DevApp[Dev App]
                StagingApp[Staging App]
                ProdApp[Production App]
            end

            subgraph Infra["Infrastructure"]
                Monitoring[Prometheus + Node Exporter<br/>+ cAdvisor]
                Alloy[Grafana Alloy<br/>Log Shipper]
                Falco[Falco eBPF<br/>Runtime Security]
            end
        end
    end

    subgraph Monitoring["Monitoring VPS"]
        Prometheus[Prometheus<br/>remote-write receiver]
        Grafana[Grafana]
        Loki[Loki]
    end

    User --> CF
    CF --> WAF --> Access --> Tunnel
    Tunnel --> Cloudflared
    Cloudflared -->|HTTP| Caddy
    Cloudflared -->|SSH| SSH

    CI -->|Service Token| Access
    Access -->|SSH tunnel| SSH

    Caddy --> DevApp
    Caddy --> StagingApp
    Caddy --> ProdApp

    Monitoring -.->|remote_write| Prometheus
    Alloy -.->|push| Loki
    CrowdSec -.->|threat intel| Host
```

## Security Layers

```mermaid
graph LR
    subgraph Layer1["Layer 1: Edge (Cloudflare)"]
        WAF[Managed WAF]
        DDoS[DDoS Protection]
        BotMgmt[Bot Management]
        CustomRules[Custom Rules<br/>5 rules]
        RateLimit[Rate Limiting<br/>login/auth]
    end

    subgraph Layer2["Layer 2: Access (Zero Trust)"]
        AzureAD[Azure AD IdP]
        AccessApps[Access Applications]
        ServiceTokens[Service Tokens<br/>CI/CD]
    end

    subgraph Layer3["Layer 3: Transport"]
        Tunnel[Cloudflare Tunnel<br/>Post-Quantum QUIC]
        NoPublicPorts[Zero Public Ports<br/>UFW deny all]
    end

    subgraph Layer4["Layer 4: Host OS"]
        UFW[UFW Firewall]
        fail2ban[fail2ban]
        CrowdSec[CrowdSec + Bouncer<br/>deny_log]
        Auditd[auditd]
        SSH[SSH Hardening<br/>key-only, AllowUsers]
        Sysctl[Kernel Hardening<br/>sysctl]
        AppArmor[AppArmor]
    end

    subgraph Layer5["Layer 5: Container"]
        NoPrivileged[No Privileged<br/>hosting-deploy policy]
        NoSocket[No Docker Socket]
        NoPublish[No Port Publishing]
        ResourceLimits[CPU/Memory/PID Limits]
        ReadOnly[Read-Only Filesystems]
        NoNewPriv[no-new-privileges]
        ICC[ICC Disabled<br/>default bridge]
        Falco[Falco eBPF<br/>Runtime Detection]
    end

    subgraph Layer6["Layer 6: Secrets"]
        SOPS[SOPS + age<br/>Encrypted at rest]
        FileSecrets[File-based Secrets<br/>GID 1999]
        NoEnvSecrets[No env var secrets]
    end

    subgraph Layer7["Layer 7: Monitoring"]
        Prometheus[Prometheus Metrics]
        Loki[Log Shipping to Loki]
        Trivy[Trivy CVE Scans<br/>Weekly]
        AIDE[AIDE File Integrity<br/>Daily]
        rkhunter[rkhunter<br/>Weekly]
    end

    Layer1 --> Layer2 --> Layer3 --> Layer4 --> Layer5 --> Layer6
    Layer4 --> Layer7
    Layer5 --> Layer7
```

## CI/CD Trust Chain

```mermaid
sequenceDiagram
    participant Dev as Developer
    participant GH as GitHub
    participant CF as Cloudflare Access
    participant SSH as VM (sshd)
    participant Deploy as hosting-deploy
    participant Docker as Docker Compose

    Dev->>GH: git push (triggers workflow)
    GH->>GH: Build + Test + Push image to GHCR

    Note over GH,CF: Service Token Auth
    GH->>CF: SSH via cloudflared (service token)
    CF->>CF: Validate service token
    CF->>SSH: Forward SSH connection

    Note over SSH,Deploy: ForceCommand restriction
    SSH->>SSH: hosting-ci-ssh (ForceCommand)
    SSH->>Deploy: sudo hosting-deploy sync --env staging
    Deploy->>Deploy: Extract tar.gz (safe extraction)
    Deploy->>Deploy: Validate compose (security policy)
    Deploy->>Deploy: Rate limit check (60s minimum)

    SSH->>Deploy: sudo hosting-deploy deploy --env staging
    Deploy->>Deploy: SOPS decrypt .env.*.enc
    Deploy->>Deploy: Policy validation (no privileged, no socket, etc.)
    Deploy->>Docker: docker compose up -d
    Docker->>Docker: Pull image, start containers
    Deploy->>Deploy: Log deployment
```

## Backup Pipeline

```mermaid
graph TB
    subgraph Daily["Daily (02:00 - 02:45 UTC)"]
        DB[Database Dumps<br/>PostgreSQL pg_dump]
        N8N[n8n Exports<br/>Workflows + Credentials]
        MinIO[MinIO Mirror<br/>mc mirror]
        Retention[Retention Cleanup<br/>30-day rotation]
        Restic[Restic Off-Site<br/>Encrypted + Deduplicated]
    end

    subgraph Weekly["Weekly (Sunday)"]
        ResticCheck[Restic Integrity Check]
        ResticPrune[Restic Prune<br/>7 daily, 4 weekly, 6 monthly]
    end

    subgraph Storage["Storage Targets"]
        Local[/srv/backups/<br/>Local Disk]
        OffSite[Hetzner Storage Box<br/>SFTP / Restic]
    end

    subgraph Monitoring["Monitoring"]
        Metrics[Prometheus Metrics<br/>backup_last_timestamp<br/>backup_offsite_last_timestamp]
        Alerts[Grafana Alerts<br/>Stale backup detection]
    end

    DB -->|02:00| Local
    N8N -->|02:15| Local
    MinIO -->|02:15| Local
    Retention -->|02:30| Local
    Local -->|02:45| Restic --> OffSite

    ResticCheck -->|Sunday| OffSite
    ResticPrune -->|Sunday| OffSite

    Local --> Metrics --> Alerts
    OffSite --> Metrics
```

## Container Network Topology

```mermaid
graph TB
    subgraph External["External Access (Cloudflare Tunnel)"]
        Cloudflared[cloudflared]
    end

    subgraph CaddyProxy["Reverse Proxy"]
        Caddy[Caddy :80<br/>localhost only]
    end

    subgraph DevNet["dev-web / dev-backend"]
        DevApp[Dev App]
        DevDB[(Dev PostgreSQL)]
    end

    subgraph StagingNet["staging-web / staging-backend"]
        StagingApp[Staging App]
        StagingDB[(Staging PostgreSQL)]
    end

    subgraph ProdNet["prod-web / prod-backend"]
        ProdApp[Production App]
        ProdDB[(Production PostgreSQL)]
    end

    subgraph ServicesNet["services-net"]
        ServicesDB[(Services PostgreSQL)]
        MinIOSvc[MinIO]
    end

    subgraph MonitoringNet["monitoring"]
        NodeExp[Node Exporter]
        Prom[Prometheus]
        cAdvisor[cAdvisor]
        Alloy[Alloy]
        Falco[Falco]
    end

    Cloudflared --> Caddy
    Caddy -.->|dev-web| DevApp
    Caddy -.->|staging-web| StagingApp
    Caddy -.->|prod-web| ProdApp

    DevApp -->|dev-backend| DevDB
    StagingApp -->|staging-backend| StagingDB
    ProdApp -->|prod-backend| ProdDB

    DevApp -.->|services-net| ServicesDB
    StagingApp -.->|services-net| ServicesDB
    ProdApp -.->|services-net| ServicesDB

    NodeExp -->|monitoring| Prom
    cAdvisor -->|monitoring| Prom
    Falco -->|monitoring| Prom
```
