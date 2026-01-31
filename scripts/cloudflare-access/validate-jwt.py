#!/usr/bin/env python3
"""
Cloudflare Access JWT Validation - Python

Validates the Cf-Access-Jwt-Assertion header sent by Cloudflare Access.

Install dependencies:
    pip install PyJWT requests cryptography

Usage:
    from validate_jwt import validate_access_jwt, access_required

    # Validate manually
    user = validate_access_jwt(token)

    # As Flask decorator
    @app.route('/admin')
    @access_required
    def admin():
        return jsonify(email=g.cf_access['email'])
"""

import os
import jwt
import requests
from functools import wraps
from typing import Optional

# Configuration - These MUST be set via environment variables
TEAM_DOMAIN = os.environ.get('CF_TEAM_DOMAIN')
AUD_TAG = os.environ.get('CF_AUD_TAG')

# Validate required configuration at import time
_config_validated = False

def _validate_config():
    """Validate required environment variables are set."""
    global _config_validated
    if _config_validated:
        return

    missing = []
    if not TEAM_DOMAIN:
        missing.append('CF_TEAM_DOMAIN')
    if not AUD_TAG:
        missing.append('CF_AUD_TAG')

    if missing:
        raise ValueError(
            f"Missing required environment variables: {', '.join(missing)}. "
            "Set CF_TEAM_DOMAIN to your Cloudflare team domain (e.g., 'mycompany.cloudflareaccess.com') "
            "and CF_AUD_TAG to your application's audience tag from Cloudflare Access."
        )
    _config_validated = True

# Cache for public keys
_keys_cache = None
_keys_cache_time = 0
CACHE_DURATION = 86400  # 24 hours


def get_public_keys() -> list:
    """Fetch and cache public keys from Cloudflare."""
    global _keys_cache, _keys_cache_time
    import time

    _validate_config()  # Ensure config is valid before making requests

    current_time = time.time()
    if _keys_cache and (current_time - _keys_cache_time) < CACHE_DURATION:
        return _keys_cache

    url = f'https://{TEAM_DOMAIN}/cdn-cgi/access/certs'
    response = requests.get(url, timeout=10)
    response.raise_for_status()

    _keys_cache = response.json()['keys']
    _keys_cache_time = current_time

    return _keys_cache


def validate_access_jwt(token: str) -> dict:
    """
    Validate Cloudflare Access JWT.

    Args:
        token: The JWT from Cf-Access-Jwt-Assertion header

    Returns:
        Decoded token payload with user info

    Raises:
        jwt.InvalidTokenError: If token is invalid
        ValueError: If required environment variables not set
        Exception: If no matching key found
    """
    _validate_config()  # Fail fast if not configured
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


# Flask integration
def access_required(f):
    """Flask decorator to require Cloudflare Access authentication."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        from flask import request, jsonify, g

        token = request.headers.get('Cf-Access-Jwt-Assertion')
        if not token:
            return jsonify(
                error='Unauthorized',
                message='No Cloudflare Access token provided'
            ), 401

        try:
            decoded = validate_access_jwt(token)
            g.cf_access = {
                'email': decoded.get('email'),
                'sub': decoded.get('sub'),
                'iat': decoded.get('iat'),
                'exp': decoded.get('exp'),
                'token': decoded,
            }
        except Exception as e:
            return jsonify(
                error='Unauthorized',
                message='Invalid Cloudflare Access token'
            ), 401

        return f(*args, **kwargs)

    return decorated_function


def access_optional(f):
    """Flask decorator that validates token if present but doesn't require it."""
    @wraps(f)
    def decorated_function(*args, **kwargs):
        from flask import request, g

        token = request.headers.get('Cf-Access-Jwt-Assertion')
        g.cf_access = None

        if token:
            try:
                decoded = validate_access_jwt(token)
                g.cf_access = {
                    'email': decoded.get('email'),
                    'sub': decoded.get('sub'),
                    'iat': decoded.get('iat'),
                    'exp': decoded.get('exp'),
                    'token': decoded,
                }
            except Exception:
                pass

        return f(*args, **kwargs)

    return decorated_function


# FastAPI integration
class CloudflareAccessMiddleware:
    """FastAPI middleware for Cloudflare Access authentication."""

    def __init__(self, app, required: bool = True):
        self.app = app
        self.required = required

    async def __call__(self, scope, receive, send):
        if scope['type'] != 'http':
            await self.app(scope, receive, send)
            return

        headers = dict(scope['headers'])
        token = headers.get(b'cf-access-jwt-assertion', b'').decode()

        if not token and self.required:
            from starlette.responses import JSONResponse
            response = JSONResponse(
                {'error': 'Unauthorized', 'message': 'No token'},
                status_code=401
            )
            await response(scope, receive, send)
            return

        if token:
            try:
                decoded = validate_access_jwt(token)
                scope['cf_access'] = {
                    'email': decoded.get('email'),
                    'sub': decoded.get('sub'),
                }
            except Exception:
                if self.required:
                    from starlette.responses import JSONResponse
                    response = JSONResponse(
                        {'error': 'Unauthorized', 'message': 'Invalid token'},
                        status_code=401
                    )
                    await response(scope, receive, send)
                    return
                scope['cf_access'] = None
        else:
            scope['cf_access'] = None

        await self.app(scope, receive, send)


if __name__ == '__main__':
    print('Cloudflare Access JWT Validator')
    print('================================')
    print()
    print('Required environment variables:')
    print('  CF_TEAM_DOMAIN - Your Cloudflare team domain (e.g., mycompany.cloudflareaccess.com)')
    print('  CF_AUD_TAG     - Your application audience tag (from Cloudflare Access app config)')
    print()

    # Show current configuration status
    if TEAM_DOMAIN and AUD_TAG:
        print(f'Current configuration:')
        print(f'  Team Domain: {TEAM_DOMAIN}')
        print(f'  AUD Tag: {AUD_TAG}')
        print()
        print('Configuration OK - ready to use.')
    else:
        print('Configuration status:')
        print(f'  CF_TEAM_DOMAIN: {"SET" if TEAM_DOMAIN else "NOT SET (required)"}')
        print(f'  CF_AUD_TAG: {"SET" if AUD_TAG else "NOT SET (required)"}')
        print()
        print('WARNING: Environment variables not configured.')
        print('Set them before using this module in your application.')

    print()
    print('Example Flask usage:')
    print()
    print('  from validate_jwt import access_required')
    print()
    print("  @app.route('/admin')")
    print('  @access_required')
    print('  def admin():')
    print("      return jsonify(email=g.cf_access['email'])")
    print()
    print('Example FastAPI usage:')
    print()
    print('  from validate_jwt import CloudflareAccessMiddleware')
    print()
    print('  app.add_middleware(CloudflareAccessMiddleware)')
