"""
URL configuration for my_golf_app project.

The `urlpatterns` list routes URLs to views. For more information please see:
    https://docs.djangoproject.com/en/6.0/topics/http/urls/
Examples:
Function views
    1. Add an import:  from my_app import views
    2. Add a URL to urlpatterns:  path('', views.home, name='home')
Class-based views
    1. Add an import:  from other_app.views import Home
    2. Add a URL to urlpatterns:  path('', Home.as_view(), name='home')
Including another URLconf
    1. Import the include() function: from django.urls import include, path
    2. Add a URL to urlpatterns:  path('blog/', include('blog.urls'))
"""
from django.conf import settings
from django.contrib import admin
from django.http import JsonResponse
from django.urls import path, include
from django.views.decorators.cache import cache_control

from api import watch_views
from api import invite_views


@cache_control(max_age=3600)
def apple_app_site_association(request):
    """iOS universal-links association file.  Served (no auth, application/json,
    no redirect) at BOTH /.well-known/... and the legacy root path Apple also
    probes.  Declares that the Halved app owns /watch/* on this domain, so
    tapping a https://halved.golf/watch/<token>/ link opens the app when it's
    installed.  appID = <TeamID>.<bundleID>."""
    return JsonResponse({
        'applinks': {
            'apps': [],
            'details': [
                {'appID': settings.IOS_APP_ID, 'paths': ['/watch/*']},
            ],
        },
    })


@cache_control(max_age=3600)
def android_assetlinks(request):
    """Android App Links association file — the Android counterpart of the
    apple-app-site-association above.  Android fetches it at install time and
    only routes https://<this domain>/watch/... into the app if one of the
    listed SHA-256 fingerprints matches the certificate the installed build was
    signed with.  Unlike Apple's file this one takes no paths: the URL patterns
    live in the app's intent-filter, and this file only answers "may that app
    speak for this domain?".

    With no fingerprints configured it returns an empty list, which is valid
    JSON and simply verifies as "no".  See ANDROID_CERT_FINGERPRINTS."""
    return JsonResponse([
        {
            'relation': ['delegate_permission/common.handle_all_urls'],
            'target': {
                'namespace': 'android_app',
                'package_name': settings.ANDROID_APP_PACKAGE,
                'sha256_cert_fingerprints': settings.ANDROID_CERT_FINGERPRINTS,
            },
        },
    ], safe=False)


urlpatterns = [
    path('admin/', admin.site.urls),
    path('api/',   include('api.urls')),

    # iOS universal-links association (must be reachable at both paths, HTTPS,
    # content-type application/json, no redirect — mind Cloudflare rewrites).
    path('.well-known/apple-app-site-association', apple_app_site_association),
    path('apple-app-site-association', apple_app_site_association),

    # Android App Links association (HTTPS, application/json, no redirect).
    path('.well-known/assetlinks.json', android_assetlinks),

    # Public spectator pages — token-gated, no auth, plain HTML.
    # Shared by the mobile app's "Share Watch Link" button.
    # card.png BEFORE the page route: both live under /watch/<token>/ and
    # the page pattern would otherwise swallow the filename.
    path('watch/<str:token>/card.png', watch_views.watch_card_png,
         name='watch-card-png'),
    path('watch/<str:token>/scorecard/', watch_views.watch_shared_scorecard,
         name='watch-shared-scorecard'),
    path('watch/<str:token>/', watch_views.watch_cup_round,
         name='watch-cup-round'),

    # Public invite landing page — shared by the in-app "Invite Friends" button.
    path('i/<str:code>/', invite_views.invite_landing, name='invite-landing'),
]
