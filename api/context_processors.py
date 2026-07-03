from django.conf import settings


def public_links(request):
    """Expose public link settings to every template (watch pages + invite
    landing) so the "Get the app" CTAs point at the real App Store URL and the
    canonical base URL is available without threading it through each view."""
    return {
        'app_download_url': settings.APP_DOWNLOAD_URL,
        'public_base_url':  settings.PUBLIC_BASE_URL,
    }
