"""
api/templatetags/share_tags.py
------------------------------
Open Graph values for the watch page, resolved from the `round` already in
every watch template's context.

A tag rather than a context processor or an argument threaded through each
view: the watch templates are rendered from a dozen different functions in
watch_views, and adding the same dict to every render() call is a dozen
chances to forget one. The tag lives in base.html, so every page that
extends it gets the tags, including ones written later.
"""
from django import template

register = template.Library()


@register.simple_tag
def share_meta(round_obj):
    """OG values for this round, or {} when there is no round in context."""
    if round_obj is None:
        return {}
    try:
        from api.watch_views import share_meta as _meta
        return _meta(round_obj)
    except Exception:
        # A share card must never be the reason a spectator page 500s.
        return {}
