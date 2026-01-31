/**
 * Cloudflare Access JWT Validation - Node.js
 *
 * Validates the Cf-Access-Jwt-Assertion header sent by Cloudflare Access.
 *
 * Install dependencies:
 *   npm install jsonwebtoken jwks-rsa
 *
 * Usage:
 *   const { validateAccessJWT, accessMiddleware } = require('./validate-jwt');
 *
 *   // As Express middleware
 *   app.use(accessMiddleware);
 *
 *   // Or validate manually
 *   const user = await validateAccessJWT(token);
 */

const jwt = require('jsonwebtoken');
const jwksClient = require('jwks-rsa');

// Configuration - Update these values
const TEAM_DOMAIN = process.env.CF_TEAM_DOMAIN || 'mycompany.cloudflareaccess.com';
const AUD_TAG = process.env.CF_AUD_TAG || 'your-application-aud-tag';

// JWKS client with caching
const client = jwksClient({
  jwksUri: `https://${TEAM_DOMAIN}/cdn-cgi/access/certs`,
  cache: true,
  cacheMaxAge: 86400000, // 24 hours
  rateLimit: true,
  jwksRequestsPerMinute: 10,
});

/**
 * Get signing key from JWKS
 */
function getKey(header, callback) {
  client.getSigningKey(header.kid, (err, key) => {
    if (err) {
      callback(err);
      return;
    }
    const signingKey = key.getPublicKey();
    callback(null, signingKey);
  });
}

/**
 * Validate Cloudflare Access JWT
 * @param {string} token - The JWT from Cf-Access-Jwt-Assertion header
 * @returns {Promise<object>} Decoded token payload with user info
 */
function validateAccessJWT(token) {
  return new Promise((resolve, reject) => {
    jwt.verify(
      token,
      getKey,
      {
        audience: AUD_TAG,
        issuer: `https://${TEAM_DOMAIN}`,
        algorithms: ['RS256'],
      },
      (err, decoded) => {
        if (err) {
          reject(err);
        } else {
          resolve(decoded);
        }
      }
    );
  });
}

/**
 * Express middleware for Cloudflare Access authentication
 */
async function accessMiddleware(req, res, next) {
  const token = req.headers['cf-access-jwt-assertion'];

  if (!token) {
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'No Cloudflare Access token provided',
    });
  }

  try {
    const decoded = await validateAccessJWT(token);

    // Add user info to request
    req.cfAccess = {
      email: decoded.email,
      sub: decoded.sub,
      iat: decoded.iat,
      exp: decoded.exp,
      // Full decoded token available if needed
      token: decoded,
    };

    next();
  } catch (err) {
    console.error('Access JWT validation failed:', err.message);
    return res.status(401).json({
      error: 'Unauthorized',
      message: 'Invalid Cloudflare Access token',
    });
  }
}

/**
 * Optional: Middleware that allows requests without token (for mixed endpoints)
 */
async function optionalAccessMiddleware(req, res, next) {
  const token = req.headers['cf-access-jwt-assertion'];

  if (!token) {
    req.cfAccess = null;
    return next();
  }

  try {
    const decoded = await validateAccessJWT(token);
    req.cfAccess = {
      email: decoded.email,
      sub: decoded.sub,
      iat: decoded.iat,
      exp: decoded.exp,
      token: decoded,
    };
  } catch (err) {
    req.cfAccess = null;
  }

  next();
}

module.exports = {
  validateAccessJWT,
  accessMiddleware,
  optionalAccessMiddleware,
  TEAM_DOMAIN,
  AUD_TAG,
};

// Example usage when run directly
if (require.main === module) {
  console.log('Cloudflare Access JWT Validator');
  console.log('================================');
  console.log(`Team Domain: ${TEAM_DOMAIN}`);
  console.log(`AUD Tag: ${AUD_TAG}`);
  console.log('');
  console.log('Environment variables:');
  console.log('  CF_TEAM_DOMAIN - Your Cloudflare team domain');
  console.log('  CF_AUD_TAG     - Your application audience tag');
  console.log('');
  console.log('Example Express usage:');
  console.log('');
  console.log("  const { accessMiddleware } = require('./validate-jwt');");
  console.log('');
  console.log('  // Protect all routes');
  console.log('  app.use(accessMiddleware);');
  console.log('');
  console.log('  // Or protect specific routes');
  console.log("  app.get('/admin', accessMiddleware, (req, res) => {");
  console.log('    res.json({ email: req.cfAccess.email });');
  console.log('  });');
}
