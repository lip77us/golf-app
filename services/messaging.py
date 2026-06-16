"""
services/messaging.py — round message threads (Phase 1).

A thread is created lazily per round. Authorization/audience is the leaderboard
reader set (round participants across all foursomes + invited watchers), which
the caller resolves via accounts.scoring_access.round_for_reader. Both human
`user` messages and server `event` messages live in the same thread.

Phase 1 scope: round threads + chat + read state. Event emission (birdie /
skin / …) calls post_event() from the scoring hooks; push delivery is layered
on top later.
"""
from tournament.models import Message, MessageThread, ThreadRead


def get_or_create_thread(round_obj) -> MessageThread:
    thread, _ = MessageThread.objects.get_or_create(round=round_obj)
    return thread


def list_messages(thread, *, since_id=0, limit=500):
    """Messages with id > since_id, oldest first (catch-up / incremental sync)."""
    return list(
        thread.messages.select_related('author')
        .filter(id__gt=since_id)
        .order_by('id')[:limit]
    )


def post_user_message(thread, author_player, body):
    """Post a human chat message; returns None for an empty body."""
    body = (body or '').strip()
    if not body:
        return None
    return Message.objects.create(
        thread=thread, kind=Message.KIND_USER, author=author_player, body=body,
    )


def post_event(thread, *, event_key, body, data=None):
    """Idempotent server event post, keyed by `event_key` (must be non-empty),
    so scoring recalcs that re-detect the same event don't double-post. Returns
    the existing message when the key was already used."""
    obj, _ = Message.objects.get_or_create(
        thread=thread, event_key=event_key,
        defaults={'kind': Message.KIND_EVENT, 'body': body, 'data': data or {}},
    )
    return obj


def mark_read(thread, user, last_message_id):
    ThreadRead.objects.update_or_create(
        thread=thread, user=user,
        defaults={'last_read_message_id': int(last_message_id or 0)},
    )


def unread_count(thread, user) -> int:
    last = (
        ThreadRead.objects.filter(thread=thread, user=user)
        .values_list('last_read_message_id', flat=True)
        .first()
    ) or 0
    return thread.messages.filter(id__gt=last).count()
