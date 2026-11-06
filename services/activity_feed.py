"""Tell the operator's Slack channels who signed up and who is playing.

Two incoming webhooks, one per channel (Paul, 3 Nov 2026):

* ``SLACK_ACTIVITY_WEBHOOK_URL`` — accounts: a new signup and its profile
  (#halved-users).
* ``SLACK_ROUNDS_WEBHOOK_URL`` — rounds started and finished
  (#halved-activity).  **Unset falls back to the accounts webhook**, so the
  rounds keep arriving in the old channel until the new URL is configured
  rather than going silent.

Both unset is off, so local servers and tests say nothing.

Three moments, and the round gets two of them on purpose: **a round is announced
at its first real score as well as when it completes**, because plenty of casual
rounds are played and never closed, and creating a round proves nothing.

* **The signup carries the PHONE.  Nothing else carries contact details.**
  (Paul, 6 Nov 2026, reversing his own 1 Nov call.)  A new account IS a phone
  number and almost nothing else — the name arrives later, from profile setup —
  so the number is what makes the notice actionable instead of a row to go and
  look up.

  **It is for internal Halved support and nothing else** (Paul, 6 Nov 2026):
  identifying the account so the golfer can be helped.  Not marketing, not a
  list, not passed on — which is what section 4 of the policy now states, in
  those words.

  It goes on the SIGNUP alone.  ``profile_completed`` lands minutes later about
  the same person and would repeat the number for no new information, and the
  round messages never carry one.  Email stays out at every moment: there is
  nothing it answers that the user id does not.

  **The constraint is the privacy policy, not this module.**  Section 4
  discloses the channel and what reaches it, and section 11's flat *"we share
  it only with our SMS delivery provider"* was amended in the same commit
  because this change made it untrue.  A third message that wants a number
  amends the policy first.
* **Never raises and never makes a golfer wait.**  The caller is a sign-in or a
  score; delivery runs off the request, after the commit, so a rolled-back score
  announces nothing.
* **The webhook URL is a credential**, so a failure logs the exception's type
  only: an httpx message can carry the URL.
"""
import logging

import httpx
from django.conf import settings
from django.db import transaction

from services.offload import run_off_request

logger = logging.getLogger(__name__)

# Past this a list of names is longer than the fact it reports.
MAX_NAMED_GOLFERS = 6

DEFAULT_PLAYER_NAME = 'New Golfer'


ACCOUNTS = 'accounts'
ROUNDS = 'rounds'


def _setting(name) -> str:
    return (getattr(settings, name, '') or '').strip()


def _webhook_url(feed: str = ACCOUNTS) -> str:
    accounts = _setting('SLACK_ACTIVITY_WEBHOOK_URL')
    if feed == ROUNDS:
        return _setting('SLACK_ROUNDS_WEBHOOK_URL') or accounts
    return accounts


def enabled(feed: str = ACCOUNTS) -> bool:
    return bool(_webhook_url(feed))


def rounds_enabled() -> bool:
    return enabled(ROUNDS)


def _esc(text) -> str:
    """Slack's three control characters; golfer names are free text."""
    return (str(text).replace('&', '&amp;')
            .replace('<', '&lt;').replace('>', '&gt;'))


def _deliver(url: str, text: str):
    try:
        httpx.post(url, json={'text': text}, timeout=5).raise_for_status()
    except Exception as exc:
        logger.warning('activity feed post failed: %s', type(exc).__name__)


def _announce(text: str, feed: str = ACCOUNTS):
    url = _webhook_url(feed)
    if not url:
        return
    transaction.on_commit(lambda: run_off_request(
        lambda: _deliver(url, text), label='activity feed'))


def _game_label(slug: str) -> str:
    from core.models import GameType
    if slug == 'low_net_round':
        return 'Stroke Play'     # the enum still says Low Net (Round)
    try:
        return str(GameType(slug).label)
    except ValueError:
        return slug


def _games(round_obj) -> str:
    """The round's games, its primary first."""
    active = list(round_obj.active_games or [])
    primary = round_obj.primary_game
    if primary in active:
        active = [primary] + [g for g in active if g != primary]
    return ', '.join(_game_label(g) for g in active)


def _roster(round_obj) -> list:
    from tournament.models import FoursomeMembership
    return list(
        FoursomeMembership.objects
        .filter(foursome__round=round_obj, player__is_phantom=False)
        .order_by('foursome__group_number', 'id')
        .values_list('player__name', 'player__phone', 'player__user_id'))


def _on_halved_count(roster) -> int:
    """A golfer is On Halved when he IS a login or his phone matches one, the
    same phone match the My Golfers badge uses."""
    from accounts.phone import normalize
    from django.contrib.auth import get_user_model
    phones = {normalize(phone) for _, phone, _ in roster if phone}
    phones.discard(None)
    known = set(get_user_model().objects.filter(phone__in=phones)
                .values_list('phone', flat=True))
    return sum(1 for _, phone, user_id in roster
               if user_id or (phone and normalize(phone) in known))


def _organiser(round_obj) -> str:
    if round_obj.created_by_id:
        return round_obj.created_by.name
    return round_obj.account.name


def round_message(round_obj, headline: str) -> str:
    roster = _roster(round_obj)
    on_halved = _on_halved_count(roster)
    lines = [
        headline,
        f'Name: {_esc(_organiser(round_obj))}',
        f'Course: {_esc(round_obj.course.name)}',
        f'Games: {_games(round_obj) or "none set"}',
        f'Players: {len(roster)} ({on_halved} on Halved, '
        f'{len(roster) - on_halved} not)',
    ]
    if 0 < len(roster) <= MAX_NAMED_GOLFERS:
        lines.append('Golfers: ' + ', '.join(_esc(n) for n, _, _ in roster))
    if round_obj.tournament_id:
        lines.append(f'Tournament: {_esc(round_obj.tournament.name)}')
    return '\n'.join(lines)


def _safely(what, compose, feed: str = ACCOUNTS):
    if not enabled(feed):
        return
    try:
        _announce(compose(), feed)
    except Exception:
        logger.exception('activity feed could not compose %s', what)


def _device(user, platform=None) -> str:
    """Best effort.  The client states it at sign-in from the build that sends
    it.  Failing that a push token names the platform, but a missing token says
    nothing: iOS tokens have never registered in production."""
    from accounts.models import DeviceToken
    if platform not in ('ios', 'android'):
        platform = (DeviceToken.objects.filter(user=user)
                    .exclude(platform='').order_by('-updated_at')
                    .values_list('platform', flat=True).first())
    return {'ios': 'iOS', 'android': 'Android'}.get(platform, 'unknown')


def _user_message(headline, user, player, platform=None,
                  *, with_phone=False) -> str:
    """The shared shape.  [with_phone] is the signup's alone — see the module
    docstring for why, and the privacy policy for what permits it."""
    name = player.name if player else DEFAULT_PLAYER_NAME
    lines = [
        headline,
        f'Name: {"not given" if name == DEFAULT_PLAYER_NAME else _esc(name)}',
    ]
    if with_phone:
        # E.164 as stored, so it pastes straight into a lookup. A legacy
        # password-only user has none; say so rather than printing None.
        lines.append(f'Phone: {_esc(user.phone) if user.phone else "not given"}')
    lines += [
        f'User: {user.id}',
        f'Device: {_device(user, platform)}',
    ]
    return '\n'.join(lines)


def user_registered(user, platform=None):
    """A phone number nobody had seen just created an account."""
    def compose():
        from core.models import Player
        return _user_message(':wave: New Halved account', user,
                             Player.objects.filter(user=user).first(), platform,
                             with_phone=True)
    _safely('signup', compose)


def profile_completed(user, player):
    """What sign-in could not know: the name from profile setup, and a device
    whose push token has registered by now."""
    _safely('profile', lambda: _user_message(
        ':bust_in_silhouette: Profile updated', user, player))


def _watch_url(round_obj) -> str:
    base = (getattr(settings, 'PUBLIC_BASE_URL', '') or '').rstrip('/')
    return f'{base}/watch/{round_obj.watch_token}/'


def round_started(round_obj):
    _safely('round start', lambda: '\n'.join([
        round_message(round_obj, ':golf: Round started'),
        f'Watch: {_watch_url(round_obj)}',
    ]), ROUNDS)


def round_finished(round_obj):
    _safely('round finish',
            lambda: round_message(round_obj, ':checkered_flag: Round finished'),
            ROUNDS)
