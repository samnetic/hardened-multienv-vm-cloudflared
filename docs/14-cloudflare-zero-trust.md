# Cloudflare Zero Trust (Access)

Protect your services with identity-based authentication at Cloudflare's edge.

## What It Does

```
User → Cloudflare → [Login Screen] → Tunnel → Your App
```

Before traffic reaches your VM, Cloudflare Access requires authentication. No login = no access.

## Free Tier

| Feature | Limit |
|---------|-------|
| Users | 50 |
| Identity providers | All (Google, GitHub, OTP, etc.) |
| Applications | Unlimited |
| Service tokens | Unlimited |

Beyond 50 users: $3-7/user/month.

---

## Quick Setup

### 1. Enable Zero Trust

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Select your domain → **Zero Trust** (left sidebar)
3. Create a team name (e.g., `mycompany`) → This becomes `mycompany.cloudflareaccess.com`

### 2. Configure Identity Providers

**Settings → Authentication → Login methods**

Add both for flexibility:

**One-Time PIN (OTP)**
- Click **Add new** → **One-time PIN**
- Works for any email address
- Good for occasional access

**Google OAuth** (optional)
- Click **Add new** → **Google**
- Create OAuth credentials in [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
- Add Client ID and Secret

**GitHub OAuth** (optional)
- Click **Add new** → **GitHub**
- Create OAuth app in [GitHub Settings](https://github.com/settings/developers)
- Add Client ID and Secret

### 3. Create Access Applications

For each service you want to protect:

**Access → Applications → Add an application → Self-hosted**

#### Example: Protect Netdata

```
Application name: Monitoring
Session Duration: 24 hours

Application domain:
  Subdomain: monitoring
  Domain: yourdomain.com
```

Then create a policy:

```
Policy name: Allow Team
Action: Allow

Include:
  - Emails ending in: @yourcompany.com
  - OR: Login Methods → One-time PIN (for any email)
```

#### Example: Protect n8n Admin

```
Application name: n8n Editor
Subdomain: n8n
Domain: yourdomain.com

Policy: Allow Team (same as above)
```

### 4. Set Up Webhooks (Public Access)

For n8n webhooks, use a **separate subdomain without Access protection**:

1. In Cloudflare DNS, add CNAME: `hooks` → your tunnel
2. In tunnel config, route `hooks.yourdomain.com` → `http://localhost:5678`
3. Do NOT create an Access application for this subdomain

Now:
- `n8n.yourdomain.com` → Login required (editor)
- `hooks.yourdomain.com` → Public (webhooks only)

---

## Subdomain Strategy

| Subdomain | Purpose | Access Policy |
|-----------|---------|---------------|
| `n8n.yourdomain.com` | n8n editor UI | Require login |
| `hooks.yourdomain.com` | n8n webhooks | None (public) |
| `monitoring.yourdomain.com` | Netdata | Require login |
| `staging.yourdomain.com` | Staging apps | Require login |
| `dev.yourdomain.com` | Dev apps | Require login |
| `app.yourdomain.com` | Production app | Your choice |
| `ssh.yourdomain.com` | SSH access | Service token |

---

## Service Tokens (Machine-to-Machine)

For CI/CD and API access without browser login.

### Create a Service Token

1. **Access → Service Auth → Service Tokens**
2. Click **Create Service Token**
3. Name it (e.g., `github-actions`)
4. Copy the **Client ID** and **Client Secret** immediately (shown only once)

### Use in CI/CD

```yaml
# GitHub Actions
- name: Deploy
  run: |
    curl -H "CF-Access-Client-Id: ${{ secrets.CF_SERVICE_TOKEN_ID }}" \
         -H "CF-Access-Client-Secret: ${{ secrets.CF_SERVICE_TOKEN_SECRET }}" \
         https://api.yourdomain.com/deploy
```

### Create Service Token Policy

In your Access application:

```
Policy name: Allow CI/CD
Action: Service Auth

Include:
  - Service Token: github-actions
```

---

## JWT Validation (Custom Apps)

When Access authenticates a user, it sends a signed JWT in the `Cf-Access-Jwt-Assertion` header.

Your app can validate this to:
1. Confirm request came through Access
2. Get user identity (email)
3. Implement app-level authorization

### Get Your Application's AUD Tag

1. **Access → Applications → Your App → Overview**
2. Copy the **Application Audience (AUD) Tag**

### Public Keys URL

```
https://<team-name>.cloudflareaccess.com/cdn-cgi/access/certs
```

### Node.js Validation

See `scripts/cloudflare-access/validate-jwt.js` for a complete example.

```javascript
const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

const TEAM_DOMAIN = 'mycompany.cloudflareaccess.com';
const AUD_TAG = 'your-application-aud-tag';

const client = jwksClient({
  jwksUri: `https://${TEAM_DOMAIN}/cdn-cgi/access/certs`
});

async function validateAccessJWT(token) {
  const decoded = jwt.decode(token, { complete: true });
  const key = await client.getSigningKey(decoded.header.kid);

  return jwt.verify(token, key.getPublicKey(), {
    audience: AUD_TAG,
    issuer: `https://${TEAM_DOMAIN}`
  });
}

// Express middleware
app.use(async (req, res, next) => {
  const token = req.headers['cf-access-jwt-assertion'];
  if (!token) return res.status(401).json({ error: 'No Access token' });

  try {
    req.user = await validateAccessJWT(token);
    next();
  } catch (err) {
    res.status(401).json({ error: 'Invalid token' });
  }
});
```

### Python Validation

See `scripts/cloudflare-access/validate-jwt.py` for a complete example.

```python
import jwt
import requests

TEAM_DOMAIN = 'mycompany.cloudflareaccess.com'
AUD_TAG = 'your-application-aud-tag'

def get_public_keys():
    url = f'https://{TEAM_DOMAIN}/cdn-cgi/access/certs'
    response = requests.get(url)
    return response.json()['keys']

def validate_access_jwt(token):
    keys = get_public_keys()
    header = jwt.get_unverified_header(token)

    for key in keys:
        if key['kid'] == header['kid']:
            public_key = jwt.algorithms.RSAAlgorithm.from_jwk(key)
            return jwt.decode(
                token,
                public_key,
                algorithms=['RS256'],
                audience=AUD_TAG,
                issuer=f'https://{TEAM_DOMAIN}'
            )

    raise Exception('No matching key found')
```

---

## Using the Ready-to-Use JWT Validators

This repository includes ready-to-use JWT validation scripts in `scripts/cloudflare-access/`:

### Configuration

Both validators require two environment variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `CF_TEAM_DOMAIN` | Your Cloudflare team domain | `mycompany.cloudflareaccess.com` |
| `CF_AUD_TAG` | Application audience tag (from Access app settings) | `a1b2c3d4e5...` |

**Important:** The validators will fail with a clear error if these are not set. This is intentional to prevent silent failures with invalid configuration.

### Python Validator (`validate-jwt.py`)

**Dependencies:**
```bash
pip install PyJWT requests cryptography
```

**Flask Integration:**
```python
from validate_jwt import access_required

@app.route('/admin')
@access_required
def admin():
    # User is authenticated via Cloudflare Access
    email = g.cf_access['email']
    return jsonify(message=f'Hello {email}')
```

**FastAPI Integration:**
```python
from validate_jwt import CloudflareAccessMiddleware

app = FastAPI()
app.add_middleware(CloudflareAccessMiddleware)

@app.get('/admin')
async def admin(request: Request):
    email = request.scope.get('cf_access', {}).get('email')
    return {'message': f'Hello {email}'}
```

**Optional Authentication:**
```python
from validate_jwt import access_optional

@app.route('/public')
@access_optional
def public():
    if g.cf_access:
        return f'Hello {g.cf_access["email"]}'
    return 'Hello anonymous'
```

### Node.js Validator (`validate-jwt.js`)

**Dependencies:**
```bash
npm install jsonwebtoken jwks-rsa
```

**Express Middleware:**
```javascript
const { accessRequired, accessOptional } = require('./validate-jwt');

// Require authentication
app.use('/admin', accessRequired, (req, res) => {
  res.json({ email: req.cfAccess.email });
});

// Optional authentication
app.use('/public', accessOptional, (req, res) => {
  if (req.cfAccess) {
    res.json({ message: `Hello ${req.cfAccess.email}` });
  } else {
    res.json({ message: 'Hello anonymous' });
  }
});
```

### Testing the Validators

```bash
# Test Python validator configuration
CF_TEAM_DOMAIN=mycompany.cloudflareaccess.com \
CF_AUD_TAG=your-aud-tag \
python scripts/cloudflare-access/validate-jwt.py

# Test Node.js validator
CF_TEAM_DOMAIN=mycompany.cloudflareaccess.com \
CF_AUD_TAG=your-aud-tag \
node scripts/cloudflare-access/validate-jwt.js
```

---

## Tunnel Configuration

Update your `infra/cloudflared/config.yml`:

```yaml
tunnel: your-tunnel-id
credentials-file: /etc/cloudflared/credentials.json

ingress:
  # Protected services (Access policies required)
  - hostname: n8n.yourdomain.com
    service: http://localhost:5678

  - hostname: monitoring.yourdomain.com
    service: http://localhost:19999

  # Public webhooks (no Access policy)
  - hostname: hooks.yourdomain.com
    service: http://localhost:5678

  # SSH (service token auth)
  - hostname: ssh.yourdomain.com
    service: ssh://localhost:22

  # Apps
  - hostname: app.yourdomain.com
    service: http://localhost:80

  # Catch-all
  - service: http_status:404
```

---

## Testing

### Test Protected App

1. Visit `https://monitoring.yourdomain.com`
2. Should see Cloudflare login screen
3. Enter email → receive OTP → login
4. Should reach Netdata

### Test Public Webhook

```bash
curl https://hooks.yourdomain.com/webhook/test
# Should work without authentication
```

### Test Service Token

```bash
curl -H "CF-Access-Client-Id: YOUR_ID" \
     -H "CF-Access-Client-Secret: YOUR_SECRET" \
     https://api.yourdomain.com/
# Should return 200, not redirect to login
```

### Test JWT Validation

After authenticating via Access, check your app logs for the `Cf-Access-Jwt-Assertion` header content.

---

## Troubleshooting

### "Access Denied" after authentication

- Check policy includes your email domain
- Verify application domain matches exactly
- Check session hasn't expired

### Webhook returns login page

- Ensure webhook subdomain has NO Access application
- Or create Bypass policy for webhook paths

### Service token not working

- Verify both headers are included
- Check token hasn't been revoked
- Ensure Service Auth policy exists

### JWT validation fails

- Verify AUD tag matches your application
- Check team domain is correct
- Ensure token hasn't expired

---

## Security Notes

1. **Always protect admin interfaces** - n8n editor, monitoring dashboards, admin panels
2. **Use separate subdomains for webhooks** - Cleaner than path-based bypass
3. **Validate JWT in your apps** - Don't rely solely on Access; verify the token
4. **Rotate service tokens** - Treat them like API keys
5. **Review Access logs** - Access → Logs shows all authentication attempts
