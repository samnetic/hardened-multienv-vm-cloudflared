# Initial Setup: From Zero to Running VM

This guide walks you through the complete setup process from a fresh cloud account to a hardened, production-ready VM.

**Total Time:** 30-45 minutes

---

## Quick Overview

```
┌────────────────────────────────────────────────────────────────┐
│ What You'll Accomplish                                         │
├────────────────────────────────────────────────────────────────┤
│ 1. Procure VPS/VM (5 min)                                     │
│ 2. Register domain (5 min)                                     │
│ 3. Set up Cloudflare (5 min)                                  │
│ 4. Point DNS to Cloudflare (5 min)                            │
│ 5. Set initial A record (2 min)                               │
│ 6. Prepare SSH keys (3 min)                                   │
│ 7. Run one-liner setup (15-20 min)                            │
│                                                                 │
│ Result: Zero-port hardened VM ready for production            │
└────────────────────────────────────────────────────────────────┘
```

---

## Step 1: Procure a VPS/VM Instance

### Option A: Oracle Cloud Always Free Tier (Recommended)

**Why:** 4 ARM cores, 24GB RAM, 200GB disk - FREE forever!

1. Go to [Oracle Cloud Free Tier](https://www.oracle.com/cloud/free/)
2. Click "Start for free"
3. Create account (no credit card required for ARM instances)
4. After email verification, log into console
5. Navigate: **Compute → Instances → Create Instance**

**Configuration:**
- Name: `production-vm` (or your choice)
- Image: **Ubuntu 22.04 LTS** or **Ubuntu 24.04 LTS**
- Shape:
  - Click "Change shape"
  - Select **Ampere** (ARM-based)
  - Choose: **VM.Standard.A1.Flex**
  - OCPUs: **4** (max free tier)
  - Memory: **24GB** (max free tier)
- Boot volume: **200GB** (max free tier)
- VCN: Use default (will create automatically)
- Public IPv4: **Assign public IP** (required)

**SSH Keys:**
- Select "Upload public key files"
- Upload your key (we'll generate in Step 6)
- Or paste public key contents

**Click:** Create

Wait 2-3 minutes for instance to provision.

**Save your public IP address** - you'll need it for DNS setup.

### Option B: Other Cloud Providers

#### DigitalOcean ($6/month for 1GB RAM)
```bash
# Via CLI (requires doctl)
doctl compute droplet create production-vm \
  --region nyc1 \
  --image ubuntu-22-04-x64 \
  --size s-1vcpu-1gb \
  --ssh-keys YOUR_KEY_ID
```

#### Hetzner (€4.15/month for 2GB RAM - Best value)
```bash
# Via CLI (requires hcloud)
hcloud server create \
  --name production-vm \
  --type cx11 \
  --image ubuntu-22.04 \
  --ssh-key YOUR_KEY
```

#### Linode ($5/month for 1GB RAM)
- Dashboard → Create → Linode
- Ubuntu 22.04 LTS
- Nanode 1GB plan

#### Vultr ($6/month for 1GB RAM)
- Deploy New Server → Cloud Compute
- Ubuntu 22.04 x64
- Regular Performance ($6/mo)

**Minimum Requirements (All Providers):**
- ✅ Ubuntu 22.04 or 24.04 LTS
- ✅ 2GB+ RAM (4GB+ recommended)
- ✅ 20GB+ disk (40GB+ recommended)
- ✅ Public IPv4 address

---

## Step 2: Obtain a Domain

Register a domain from any registrar.

### Recommended Registrars

| Registrar | .com Price | Notes |
|-----------|-----------|-------|
| **Cloudflare Registrar** | $9.77/year | At-cost pricing, no markup |
| Namecheap | $8.88/year first | Easy to use, good support |
| Porkbun | $8.14/year | No hidden fees |
| Google Domains | $12/year | Simple interface |

### Quick Steps (Cloudflare Registrar Example)

1. Go to [Cloudflare Registrar](https://www.cloudflare.com/products/registrar/)
2. Search for available domain
3. Add to cart and purchase
4. Domain automatically added to your Cloudflare account

**OR use any other registrar** - we'll point it to Cloudflare in Step 4.

---

## Step 3: Register Cloudflare Account

1. Go to [Cloudflare](https://cloudflare.com/)
2. Click "Sign Up"
3. Enter email and create password
4. Verify email

**No credit card required!**

### What's Included (Free Tier)

- ✅ Unlimited subdomains
- ✅ Free SSL certificates (wildcard `*.yourdomain.com`)
- ✅ DDoS protection
- ✅ CDN (global edge network)
- ✅ Zero Trust Tunnel (what we'll use)
- ✅ Automatic certificate renewal
- ✅ DNS management
- ✅ Analytics

---

## Step 4: Point Domain to Cloudflare

### If You Bought Domain from Cloudflare Registrar

✅ **Skip this step!** Your domain is already configured.

### If You Bought Domain Elsewhere

1. Log into **Cloudflare Dashboard**
2. Click **"Add a Site"**
3. Enter your domain: `yourdomain.com`
4. Click **"Add site"**
5. Select **Free Plan** → Continue
6. Cloudflare will show you nameservers:
   ```
   alexa.ns.cloudflare.com
   derek.ns.cloudflare.com
   ```

7. **Log into your domain registrar** (Namecheap, GoDaddy, etc.)
8. Find **DNS/Nameserver settings**
9. **Replace existing nameservers** with Cloudflare's
10. Save changes

**Propagation time:** 5-60 minutes (usually ~10 minutes)

Cloudflare will email you when domain is active.

---

## Step 5: Set Initial DNS A Record

⚠️ **CRITICAL:** Before tunnel setup, you need direct SSH access.

### Why?

- The setup script connects via SSH to configure everything
- Cloudflare Tunnel will handle SSH later
- For now, we need direct IP access

### Steps

1. Go to **Cloudflare Dashboard** → Your domain
2. Click **DNS** → **Records**
3. Click **Add record**

**Add root A record:**
- Type: **A**
- Name: **@** (represents yourdomain.com)
- IPv4 address: **YOUR_VM_PUBLIC_IP** (from Step 1)
- Proxy status: **DNS only** (⚠️ gray cloud - not orange!)
- TTL: **Auto**
- Click **Save**

**Add wildcard A record (optional but recommended):**
- Type: **A**
- Name: **\*** (wildcard for all subdomains)
- IPv4 address: **YOUR_VM_PUBLIC_IP**
- Proxy status: **DNS only** (gray cloud)
- TTL: **Auto**
- Click **Save**

### Why Gray Cloud (DNS Only)?

- ✅ SSH won't work through Cloudflare proxy initially
- ✅ Gives you direct SSH access for setup
- ✅ We'll change to tunnel (CNAME) after setup completes

**After tunnel setup**, we'll:
1. Remove these A records
2. Add CNAME records pointing to tunnel
3. Achieve zero-port security

---

## Step 6: Prepare SSH Keys

SSH keys provide secure authentication. We'll create/select keys on your **local machine**.

### Option A: Generate New Keys (Recommended)

```bash
# On your LOCAL MACHINE (not the VM)

# Generate ed25519 key (modern, secure)
ssh-keygen -t ed25519 -C "your-email@yourdomain.com"

# Or generate RSA 4096 key (more compatible)
ssh-keygen -t rsa -b 4096 -C "your-email@yourdomain.com"
```

**Prompts:**
```
Enter file: [Press Enter for default: ~/.ssh/id_ed25519]
Enter passphrase: [Enter passphrase or leave empty]
```

**Result:**
```
Your public key has been saved in /home/you/.ssh/id_ed25519.pub
```

### Option B: Use Existing Keys

```bash
# List your existing keys
ls -la ~/.ssh/

# Common key files:
# id_ed25519 / id_ed25519.pub
# id_rsa / id_rsa.pub
```

### Copy Your Public Key

```bash
# Display public key
cat ~/.ssh/id_ed25519.pub

# Or for RSA
cat ~/.ssh/id_rsa.pub
```

**Copy the entire output** - you'll paste it during setup.

Example output:
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbcdefghijklmnopqrstuvwxyz your-email@yourdomain.com
```

**Keep this terminal open** - you'll need to copy this key again.

---

## Step 7: SSH to VPS and Run Setup

### 7.1 Test SSH Connection

```bash
# From your LOCAL MACHINE
ssh root@YOUR_VM_PUBLIC_IP
# or
ssh ubuntu@YOUR_VM_PUBLIC_IP

# If using custom key:
ssh -i ~/.ssh/id_ed25519 root@YOUR_VM_PUBLIC_IP
```

**First connection will ask:**
```
The authenticity of host '...' can't be established.
Are you sure you want to continue connecting (yes/no)?
```

Type: **yes**

### 7.2 Run the One-Liner Setup

Once connected to your VM:

```bash
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/HEAD/bootstrap.sh | sudo bash
```

**What happens:**

1. **Pre-flight checks** (2 min)
   - Verifies Ubuntu 22.04/24.04
   - Checks RAM and disk space
   - Tests internet connectivity

2. **Repository clone** (1 min)
   - Downloads setup scripts to `/opt/hosting-blueprint`

3. **Interactive setup** (10-15 min)
   - You'll be prompted for:
     - Domain name (e.g., `yourdomain.com`)
     - SSH public keys (paste from Step 6)
     - Sysadmin sudo mode (password required recommended vs passwordless)
     - Timezone (default: UTC)
     - Cloudflare Tunnel setup? (yes/no)

4. **Automated hardening** (10 min)
   - Creates `sysadmin` and `appmgr` users
   - Hardens SSH (key-only auth)
   - Hardens kernel (ASLR, ptrace, SYN flood)
   - Installs Docker with security defaults
   - Configures firewall (UFW)
   - Installs fail2ban and auditd
   - Sets up Cloudflare Tunnel
   - Configures Caddy reverse proxy

5. **Verification** (2 min)
   - Tests all components
   - Shows security status

**Total time:** 15-20 minutes

### 7.3 During Setup - Prompts

```
Domain name (e.g., yourdomain.com): [Enter your domain]

SSH public key for sysadmin user: [Paste from Step 6]

Appmgr SSH key option [1]: [Press Enter]
Appmgr SSH Key: [Paste a dedicated deploy key]  # or choose reuse/skip

Require password for sysadmin sudo? (recommended) [Y/n]: [Press Enter]

Timezone (default: UTC): [Press Enter or type timezone]

Set up Cloudflare Tunnel now? (yes/no): yes
```

After the core setup, you'll also be asked about optional hardening (you can skip and run later):
- Enable SOPS + age for encrypted `.env.*.enc` deployments
- Install host security tools (AIDE, Lynis, rkhunter, debsums)
- Harden `/tmp` (tmpfs + `noexec,nosuid,nodev`)

### 7.4 After Setup Completes

You'll see:
```
╔══════════════════════════════════════════════════════════╗
║ Setup Verification Results                               ║
╠══════════════════════════════════════════════════════════╣
║ System Security:                         [6/6] ✓ PASS   ║
║ User Configuration:                      [5/5] ✓ PASS   ║
║ Docker Configuration:                    [5/5] ✓ PASS   ║
║ Infrastructure Services:                 [4/4] ✓ PASS   ║
║ Network & DNS:                           [5/5] ✓ PASS   ║
║ SSH Connectivity:                        [5/5] ✓ PASS   ║
╠══════════════════════════════════════════════════════════╣
║ Overall Status:                          ✓ READY         ║
║                                                          ║
║ Your VM is hardened and ready for production!           ║
╚══════════════════════════════════════════════════════════╝
```

---

## Step 8: Configure Local Machine for Tunnel SSH

After tunnel is set up, configure your **local machine** to SSH via tunnel.

### 8.1 Install cloudflared

Recommended (installs cloudflared + configures `~/.ssh/config`):

```bash
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/HEAD/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com sysadmin
curl -fsSL https://raw.githubusercontent.com/samnetic/hardened-multienv-vm-cloudflared/HEAD/scripts/setup-local-ssh.sh | bash -s -- ssh.yourdomain.com appmgr
```

Manual install (if you prefer):

- macOS: `brew install cloudflared`
- Debian/Ubuntu: install via the official repo at `https://pkg.cloudflare.com/cloudflared`
- Other Linux: download a binary from Cloudflare’s official releases (verify source)

### 8.2 Configure SSH

Add to `~/.ssh/config`:

```
# Hardened VM via Cloudflare Tunnel
Host yourdomain
  HostName ssh.yourdomain.com
  User sysadmin
  ProxyCommand cloudflared access ssh --hostname ssh.yourdomain.com
  IdentityFile ~/.ssh/id_ed25519
  ServerAliveInterval 60
  ServerAliveCountMax 3

# App manager for CI/CD
Host yourdomain-appmgr
  HostName ssh.yourdomain.com
  User appmgr
  ProxyCommand cloudflared access ssh --hostname ssh.yourdomain.com
  IdentityFile ~/.ssh/id_ed25519
```

**Replace:**
- `yourdomain` → your actual domain base (e.g., `myproject`)
- `ssh.yourdomain.com` → your actual SSH hostname
- `~/.ssh/id_ed25519` → your actual key path

### 8.3 Test SSH via Tunnel

```bash
ssh yourdomain
```

Should connect successfully!

---

## Step 9: Migrate DNS to Tunnel (Optional but Recommended)

After tunnel SSH works, hide your VM's IP address.

### Current State (Exposed IP)
```
yourdomain.com     → A record → 147.224.142.131 (EXPOSED)
*.yourdomain.com   → A record → 147.224.142.131 (EXPOSED)
ssh.yourdomain.com → CNAME   → tunnel UUID (SECURE)
```

### Desired State (Zero Exposed Ports)
```
yourdomain.com     → CNAME → tunnel UUID (SECURE)
*.yourdomain.com   → CNAME → tunnel UUID (SECURE)
ssh.yourdomain.com → CNAME → tunnel UUID (SECURE)
```

### Automated Migration

```bash
ssh yourdomain
sudo ./scripts/cleanup-exposed-dns.sh
```

This will:
1. Detect exposed A records
2. Remove them
3. Add CNAME records to tunnel
4. Verify DNS propagation

**Result:** Zero open ports! All traffic via Cloudflare Tunnel.

---

## Troubleshooting

### Can't SSH to VM

**Check:**
1. VM is running (check cloud console)
2. Public IP is correct
3. SSH port 22 is open (not blocked by cloud firewall)
4. Using correct key: `ssh -i ~/.ssh/id_ed25519 root@IP`

**Oracle Cloud specific:**
```bash
# Check default firewall rules
sudo iptables -L -n | grep 22
```

### Domain not resolving

**Check:**
1. Nameservers updated (wait 5-60 minutes)
2. DNS record added in Cloudflare
3. Test: `nslookup yourdomain.com` or `dig yourdomain.com`

### Setup script fails

**Get help:**
1. Check logs: `/opt/hosting-blueprint/setup.log`
2. Run with debug: `bash -x /opt/hosting-blueprint/setup.sh`
3. Create issue: [GitHub Issues](https://github.com/samnetic/hardened-multienv-vm-cloudflared/issues)

---

## What's Next?

After setup completes, see:

- **[SETUP.md](../SETUP.md)** - Detailed walkthrough
- **[RUNBOOK.md](../RUNBOOK.md)** - Daily operations
- **[docs/07-gitops-workflow.md](07-gitops-workflow.md)** - CI/CD setup
- **[docs/12-running-multiple-apps.md](12-running-multiple-apps.md)** - Deploy applications

---

## Summary Checklist

- [ ] VPS/VM procured (Ubuntu 22.04/24.04)
- [ ] Domain registered
- [ ] Cloudflare account created
- [ ] Domain pointed to Cloudflare nameservers
- [ ] Initial A record created (gray cloud)
- [ ] SSH keys prepared
- [ ] One-liner setup completed successfully
- [ ] Verification shows all green
- [ ] Local machine configured for tunnel SSH
- [ ] DNS migrated to tunnel (IP hidden)

**Congratulations!** You now have a production-ready, hardened VM with zero exposed ports! 🎉
