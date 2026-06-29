"""
core/signals.py
---------------
Fire a notification when a new product-feedback row lands, so we hear about it
without polling the Django admin.
"""

import json
import logging
import urllib.request

from django.conf import settings
from django.db.models.signals import post_save
from django.dispatch import receiver

from .models import GameSuggestion

logger = logging.getLogger(__name__)


@receiver(post_save, sender=GameSuggestion)
def notify_new_game_suggestion(sender, instance, created, **kwargs):
    """When a NEW game suggestion is stored, log it and — if a webhook is
    configured — POST a compact summary to it.

    `GAME_SUGGESTION_WEBHOOK_URL` accepts any incoming-webhook URL (Slack,
    Discord, Zapier, Make, …): a zero-infra way to get pinged the moment a row
    lands, until a server email backend is wired up (this is the single place
    to add that). Best-effort — a webhook failure never breaks the submission.
    """
    if not created:
        return

    summary = (
        f"New game suggestion: {instance.game_name or '(no name)'} "
        f"from {instance.submitter_name or 'someone'} "
        f"<{instance.contact_email or 'no email'}>"
    )
    logger.info('[game-suggestion] %s (id=%s)', summary, instance.id)

    url = getattr(settings, 'GAME_SUGGESTION_WEBHOOK_URL', '')
    if not url:
        return
    try:
        body = json.dumps({
            'text':           summary,   # Slack/Discord render this field
            'id':             instance.id,
            'game_name':      instance.game_name,
            'num_players':    instance.num_players,
            'num_rounds':     instance.num_rounds,
            'hole_scoring':   instance.hole_scoring,
            'betting':        instance.betting,
            'notes':          instance.notes,
            'submitter_name': instance.submitter_name,
            'contact_email':  instance.contact_email,
        }).encode()
        req = urllib.request.Request(
            url, data=body, headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req, timeout=5)
    except Exception:
        logger.exception('[game-suggestion] webhook POST failed')
