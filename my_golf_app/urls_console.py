"""
my_golf_app/urls_console.py
---------------------------
The urlconf used when a request arrives on a dedicated console hostname
(``CONSOLE_HOSTS`` — see ``console/middleware.py``).

The console sits at the ROOT here, so ``td.halved.golf/sign-in`` and
``td.halved.golf/roster/import`` are the real paths, as the design draws them.

Everything else the main urlconf serves is deliberately still reachable on this
host:

* ``/admin/`` and ``/api/`` because the console shares one Django process with
  the API, and cutting them off on one hostname would be a security theatre
  that breaks the browsable API without preventing anything — the same routes
  answer on the primary domain regardless.
* ``/td/`` because a link someone bookmarked before the subdomain existed
  should not 404 once it does.
"""

from django.urls import include, path

from my_golf_app.urls import urlpatterns as base_urlpatterns


urlpatterns = [
    # The console at the root — this host's whole purpose.
    path('', include('console.urls')),
] + base_urlpatterns
