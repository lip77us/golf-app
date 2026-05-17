"""
api/middleware.py
-----------------
Server-side diagnostics for the intermittent silent-logout bug.

Every 401 response is logged with enough context to correlate against
client-side reports — request method, path, the originating IP, and
whether the inbound request actually carried an Authorization header.
That last bit is the most informative signal: a 401 with no Auth
header means the client sent a tokenless request (a bug in the client
state), while a 401 with an Auth header means the token itself was
stale/invalid (a server-side or session-rotation issue).

Logged at WARNING via the 'api' logger so the entries show up alongside
the existing app logs in Railway / docker.
"""
from __future__ import annotations

import logging

log = logging.getLogger('api')


class AuthFailureLogger:
    """Middleware that logs every 401 response."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        response = self.get_response(request)

        if response.status_code == 401:
            auth_header = request.META.get('HTTP_AUTHORIZATION', '')
            token_sent  = auth_header.lower().startswith('token ')
            # Surface only the token prefix (first 6 chars) so the log
            # ties a specific failure to a specific token without
            # exposing the full credential.
            token_hint = ''
            if token_sent and len(auth_header) > 12:
                token_hint = f' token_prefix={auth_header[6:12]}…'

            ip = (
                request.META.get('HTTP_X_FORWARDED_FOR', '').split(',')[0].strip()
                or request.META.get('REMOTE_ADDR', '')
            )

            log.warning(
                '[AUTH-401] %s %s ip=%s auth_header=%s%s ua=%r',
                request.method,
                request.get_full_path(),
                ip,
                'present' if token_sent else 'missing',
                token_hint,
                request.META.get('HTTP_USER_AGENT', '')[:80],
            )

        return response
