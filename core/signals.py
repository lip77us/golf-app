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

    _email_game_suggestion(instance, summary)

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


def _email_game_suggestion(instance, summary):
    """Email the suggestion to GAME_SUGGESTION_NOTIFY_EMAIL (e.g. info@halved.golf)
    when configured. Reply-To is the submitter so a reply reaches them directly.
    Best-effort — a send failure never breaks the submission."""
    to_addr = getattr(settings, 'GAME_SUGGESTION_NOTIFY_EMAIL', '')
    if not to_addr:
        return
    try:
        from django.core.mail import EmailMessage
        body = '\n'.join([
            summary, '',
            f"Game name:   {instance.game_name or '—'}",
            f"Players:     {instance.num_players or '—'}",
            f"Rounds:      {instance.num_rounds or '—'}",
            '', 'How each hole is scored:', instance.hole_scoring or '—',
            '', 'How the betting works:', instance.betting or '—',
            '', 'Notes:', instance.notes or '—',
            '', f"From: {instance.submitter_name or 'someone'} "
                f"<{instance.contact_email or 'no email'}>",
            f"Suggestion #{instance.id}",
        ])
        EmailMessage(
            subject=f"[Halved] New game suggestion: "
                    f"{instance.game_name or 'untitled'}",
            body=body,
            to=[to_addr],
            reply_to=[instance.contact_email] if instance.contact_email else None,
        ).send(fail_silently=False)
    except Exception:
        logger.exception('[game-suggestion] notify email failed')
