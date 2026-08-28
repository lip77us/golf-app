"""
console/urls.py
---------------
Routes for the TD console, mounted under a single prefix by the project
urlconf (``/td/`` today).  The design draws these on a ``td.halved.golf``
subdomain; pointing that host at this service is a DNS + ALLOWED_HOSTS change,
not a routing one, so the paths below are written prefix-relative.
"""

from django.urls import path

from . import views


app_name = 'console'

urlpatterns = [
    path('',                     views.home,         name='home'),

    # Sign in — public.  The pending number lives on the session between them.
    path('sign-in/',             views.sign_in,      name='sign-in'),
    path('sign-in/code/',        views.sign_in_code, name='sign-in-code'),
    path('sign-out/',            views.sign_out,     name='sign-out'),

    # Import a Golf Genius roster.
    path('roster/import/',                    views.import_start,   name='import'),
    path('roster/import/preview/<int:pk>/',   views.import_preview, name='import-preview'),
    path('roster/import/runs/<int:number>/',  views.import_run,     name='import-run'),
    path('roster/import/runs/<int:number>/csv/',
         views.import_run_csv, name='import-run-csv'),
]
