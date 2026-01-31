# User Management

This guide covers user management best practices for your hardened VM.

## User Model Overview

This template uses a **dual-user model** with clear separation of duties:

| User | Purpose | Sudo | Docker | SSH |
|------|---------|------|--------|-----|
| `sysadmin` | System administration | Yes | Yes | Yes |
| `appmgr` | Application deployment | No | Yes | Yes |
| `root` | Emergency only | N/A | Yes | **No** |

### Why Two Users?

**Principle of Least Privilege**: Give each user only the permissions they need.

- **sysadmin** - For humans who need to configure the system, install packages, change firewall rules
- **appmgr** - For deployments (CI/CD), starting/stopping containers, viewing logs

If your CI/CD is compromised, the attacker can only affect Docker containers, not the entire system.

## User Setup

### Created During Setup

The `setup-vm.sh` script creates both users:

```bash
# sysadmin - full system access
adduser --disabled-password --gecos "" sysadmin
usermod -aG sudo sysadmin
usermod -aG docker sysadmin

# appmgr - deployment only
adduser --disabled-password --gecos "" appmgr
usermod -aG docker appmgr
# Note: NO sudo for appmgr
```

### Adding SSH Keys

```bash
# For sysadmin (your personal key)
sudo mkdir -p /home/sysadmin/.ssh
echo "ssh-ed25519 AAAA... your-email@example.com" | sudo tee /home/sysadmin/.ssh/authorized_keys
sudo chown -R sysadmin:sysadmin /home/sysadmin/.ssh
sudo chmod 700 /home/sysadmin/.ssh
sudo chmod 600 /home/sysadmin/.ssh/authorized_keys

# For appmgr (CI/CD deploy key)
sudo mkdir -p /home/appmgr/.ssh
echo "ssh-ed25519 AAAA... github-actions" | sudo tee /home/appmgr/.ssh/authorized_keys
sudo chown -R appmgr:appmgr /home/appmgr/.ssh
sudo chmod 700 /home/appmgr/.ssh
sudo chmod 600 /home/appmgr/.ssh/authorized_keys
```

## Adding Team Members

### New Administrator (Full Access)

For someone who needs sudo access:

```bash
# Create user
sudo adduser --disabled-password --gecos "Jane Doe" jane

# Add to groups
sudo usermod -aG sudo jane
sudo usermod -aG docker jane

# Add their SSH key
sudo mkdir -p /home/jane/.ssh
echo "ssh-ed25519 AAAA... jane@company.com" | sudo tee /home/jane/.ssh/authorized_keys
sudo chown -R jane:jane /home/jane/.ssh
sudo chmod 700 /home/jane/.ssh
sudo chmod 600 /home/jane/.ssh/authorized_keys
```

### New Developer (Deploy Only)

For someone who only needs to deploy:

```bash
# Create user
sudo adduser --disabled-password --gecos "John Smith" john

# Add to docker group ONLY (no sudo)
sudo usermod -aG docker john

# Add their SSH key
sudo mkdir -p /home/john/.ssh
echo "ssh-ed25519 AAAA... john@company.com" | sudo tee /home/john/.ssh/authorized_keys
sudo chown -R john:john /home/john/.ssh
sudo chmod 700 /home/john/.ssh
sudo chmod 600 /home/john/.ssh/authorized_keys
```

### Read-Only Access (Logs/Monitoring)

For someone who only needs to view logs:

```bash
# Create user with no special groups
sudo adduser --disabled-password --gecos "Support" support

# Add SSH key
sudo mkdir -p /home/support/.ssh
echo "ssh-ed25519 AAAA..." | sudo tee /home/support/.ssh/authorized_keys
sudo chown -R support:support /home/support/.ssh
sudo chmod 700 /home/support/.ssh
sudo chmod 600 /home/support/.ssh/authorized_keys

# They can run monitoring scripts but can't docker exec or sudo
```

## Removing Users

### Immediate Removal (Employee Left)

```bash
# Lock account immediately
sudo passwd -l username

# Remove from all groups
sudo deluser username sudo
sudo deluser username docker

# Archive and delete home directory
sudo tar -czf /root/backups/username-home-$(date +%Y%m%d).tar.gz /home/username
sudo userdel -r username

# Check for any running processes
ps aux | grep username
```

### Planned Removal (Role Change)

```bash
# Remove specific access
sudo deluser username sudo  # Remove admin access
# or
sudo deluser username docker  # Remove deploy access

# Verify
groups username
```

## SSH Key Management

### Generating Keys (On Your Machine)

```bash
# Generate Ed25519 key (recommended)
ssh-keygen -t ed25519 -C "your-email@example.com"

# For CI/CD, generate without passphrase
ssh-keygen -t ed25519 -C "github-actions-deploy" -f ~/.ssh/deploy_key -N ""
```

### Key Types

| Type | Recommendation | Notes |
|------|---------------|-------|
| Ed25519 | **Recommended** | Modern, fast, secure |
| RSA 4096 | Acceptable | Legacy compatibility |
| RSA 2048 | Avoid | Too weak for 2025 |
| DSA | Never | Deprecated |
| ECDSA | Avoid | NSA concerns |

### Multiple Keys Per User

For users with multiple machines:

```bash
# Add all their keys to authorized_keys
sudo nano /home/username/.ssh/authorized_keys
# Add one key per line
```

### Key Rotation

Rotate keys annually or when:
- Employee leaves
- Key might be compromised
- Security audit requires it

```bash
# Replace all keys for a user
sudo nano /home/username/.ssh/authorized_keys
# Replace content with new key(s)
```

## Service Accounts

### For CI/CD (GitHub Actions)

The `appmgr` user is designed for this:

```bash
# Generate deploy key
ssh-keygen -t ed25519 -C "github-actions" -f deploy_key -N ""

# Add public key to appmgr
sudo tee -a /home/appmgr/.ssh/authorized_keys < deploy_key.pub

# Store private key in GitHub Secrets as SSH_PRIVATE_KEY
cat deploy_key
```

### For Monitoring Tools

If you add external monitoring:

```bash
# Create dedicated monitoring user
sudo adduser --disabled-password --system --group monitoring

# Give minimal required access
# (depends on what tool needs)
```

## Audit Trail

### Who Can Do What

```bash
# List all users with sudo
grep -Po '^sudo.+:\K.*$' /etc/group

# List all users with docker
grep -Po '^docker.+:\K.*$' /etc/group

# List all users who can SSH
for user in $(ls /home); do
  if [ -f "/home/$user/.ssh/authorized_keys" ]; then
    echo "$user: $(wc -l < /home/$user/.ssh/authorized_keys) key(s)"
  fi
done
```

### Login History

```bash
# Recent logins
last -n 20

# Failed login attempts
sudo lastb -n 20

# Currently logged in
who
```

### Command History

Users' command history is in their home directories:
```bash
# View sysadmin's history (as root)
sudo cat /home/sysadmin/.bash_history

# Audit log shows sudo commands
sudo ausearch -k sudo_log
```

## Best Practices

### DO

- Use Ed25519 keys
- Give each person their own user account
- Use separate keys for CI/CD vs personal access
- Remove access immediately when someone leaves
- Rotate keys annually
- Document who has access and why

### DON'T

- Share user accounts ("everyone uses appmgr")
- Use password authentication
- Give sudo to CI/CD accounts
- Forget to remove departed employees
- Use the same key for everything
- Allow root SSH login

## Quick Reference

### Add Admin User
```bash
sudo adduser --disabled-password username
sudo usermod -aG sudo,docker username
# Add SSH key
```

### Add Deploy User
```bash
sudo adduser --disabled-password username
sudo usermod -aG docker username
# Add SSH key
```

### Remove User
```bash
sudo passwd -l username
sudo userdel -r username
```

### Check User Access
```bash
groups username
sudo cat /home/username/.ssh/authorized_keys
```
