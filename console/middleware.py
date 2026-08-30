"""
console/middleware.py
---------------------
Serve the TD console at the ROOT of its own hostname.

The console is mounted at ``/td/`` on the main service so it works with no DNS
at all.  But the design writes its routes as ``td.halved.golf/sign-in`` and
``td.halved.golf/roster/import`` — and those paths are meant literally: a TD is
given a hostname, not a path inside the API's.

So for any host listed in ``CONSOLE_HOSTS`` this swaps the urlconf for one that
mounts ``console.urls`` at the root.  ``request.urlconf`` also drives
``reverse()`` for the rest of that request, so ``{% url 'console:import' %}``
renders ``/roster/import/`` on the console host and ``/td/roster/import/``
everywhere else — one template, correct links on both.

**Off until configured.**  ``CONSOLE_HOSTS`` is empty by default, so this is a
no-op for every existing deployment; nothing changes until the env var is set
and the DNS exists.  ``/td/`` keeps working on the console host too, because
the console urlconf is additive — see ``my_golf_app/urls_console.py``.
"""

from django.conf import settings


class ConsoleHostMiddleware:
    """Route a dedicated console hostname to the console's own urlconf."""

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        # Read per-request rather than caching at startup.  The list is tiny,
        # and caching it would mean the middleware silently ignored any change
        # to the setting after the chain was built — including override_settings
        # in a test, which is exactly where a wrong answer costs the most.
        hosts = {h.strip().lower()
                 for h in getattr(settings, 'CONSOLE_HOSTS', []) if h.strip()}
        if hosts:
            # get_host() carries the port; the port is never part of the match.
            if request.get_host().split(':')[0].lower() in hosts:
                request.urlconf = 'my_golf_app.urls_console'
        return self.get_response(request)
