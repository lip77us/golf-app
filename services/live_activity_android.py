"""
services/live_activity_android.py
---------------------------------
The Android half of the lock-screen board.

**Android has no Live Activity.**  There is no phone-side surface that behaves
like one: lock screen widgets came back in Android 14 on TABLETS only, and
Android 16's "Live Updates" are a promoted ongoing notification shaped around
a progress bar — delivery, rideshare, navigation — and gated well above what a
closed-test fleet is running.  So this does not port the iOS card.  It is a
different object answering the same question: **one notification per round that
rewrites itself every hole.**

It reuses the whole composition layer unchanged.  `activity_state(rnd, user)`
is already platform-neutral and already built per recipient — which is what
makes the money line correct on each phone — so this module only flattens and
delivers.  Adding a game to the Android board is therefore nothing: a game with
a builder has one here too.

Replace, don't stack
--------------------
`AndroidNotification.tag` is what rewrites in place: a second notification
carrying the same tag REPLACES the first instead of queueing beneath it.  A
four-hour round leaves one row on the lock screen rather than eighteen.

Deliberately NOT `sticky=True`.  A sticky notification cannot be swiped away,
and **FCM cannot cancel a notification it has displayed** — taking one down
needs `NotificationManager.cancel` on the device, which is client code this
tier does not have.  A sticky board would outlive the round that produced it
and could not be dismissed by the person left holding it.  Replaced-and-
dismissable is the shape with no stuck state.

The text is a DEGRADED view, on purpose
---------------------------------------
When FCM displays a notification itself (app backgrounded), the Firebase SDK
builds it with `setContentText` and no `BigTextStyle` — so the body is one
truncated line with nothing to expand.  Every slot of a card that spends five
rows on iOS therefore collapses into `title` plus one dense `body`.

The full ordered board still travels, as `lines` in the data payload.  Nothing
reads it yet.  A client that can draw `BigTextStyle` — or a RemoteViews layout
— renders the rich version with **no server change**.  That is the seam, and it
is why `notification_text` returns `lines` rather than only the two strings it
can use today.

The channel is named forward
----------------------------
`channel_id` is sent as `halved_board`, which **does not exist yet**.  FCM falls
back to the manifest's `halved_default` when a named channel has not been
created by the app, so naming it is inert today and correct the moment a dozen
lines of Kotlin create a low-importance `halved_board`.

Until then the board posts on the default channel and **makes a sound**: on
Android 8+ sound is a property of the CHANNEL, not of the message, so no field
here can silence it.  `default_sound=False` would be theatre.  A tester who
minds can set the channel to Silent in Android settings; the channel is the
real fix, and it is the only part of this that needs a build.

Configuration
-------------
    ANDROID_BOARD=1     Off unless set.  This posts to every Android phone
                        following a round, so it is a decision somebody makes
                        rather than something a deploy switches on — the same
                        reasoning as `LIVE_ACTIVITY_ENABLED`.  Clearing the
                        variable stops it at the next restart: no code change
                        and no build, which is the entire point of this tier.

    ANDROID_BOARD_PHONES
                        Optional comma-separated E.164 list restricting the
                        board to those golfers.  **Empty means EVERYONE** -
                        see `_allowlist`.  Set it alongside `ANDROID_BOARD` in
                        ONE change when trialling, so there is no window in
                        which the fleet is switched on unrestricted.

Delivery rides `services.push.send_push`, so `PUSH_BACKEND=console` logs and
sends nothing, exactly as for every other notification.  Nothing here raises
into the caller — a board that stops updating is merely stale, while a scoring
request that fails because of one is a real problem.
"""
import logging
import os

logger = logging.getLogger(__name__)

# The channel the board WANTS.  Absent on every build shipped so far, which is
# safe: FCM falls back to the manifest default for a channel the app has not
# created.  See the module docstring.
BOARD_CHANNEL = 'halved_board'

# The notification category, so a golfer can turn the board off without
# turning off birdies.  Registered in services.push.NOTIFICATION_CATEGORIES.
CATEGORY = 'board'

# A rich client can draw more than one line; there is still no point sending a
# wall of them.  Eight covers the widest card in the set (header, ribbon, two
# sides lines, thru, money, context, tee).
MAX_LINES = 8

# What the cards put in a slot that has nothing to say.  In a laid-out card a
# dash sits in a box the eye skips; joined into one line with middots it reads
# as a value that failed to load.  Sixes sends `—` as its state word on
# every finished segment, which is five of the thirty boards in the local
# fleet.
_PLACEHOLDERS = {'—', '–', '-', '−', 'n/a', 'none'}


def _blank(s) -> bool:
    t = (s or '').strip()
    return not t or t.casefold() in _PLACEHOLDERS


def is_enabled() -> bool:
    """The one switch, off unless set.

    Not derived from `PUSH_BACKEND` being configured: going live should be a
    decision, not a side effect of credentials existing.
    """
    return (os.environ.get('ANDROID_BOARD', '') or '').lower() \
        in ('1', 'true', 'yes')


def _normalized_phone(user) -> str:
    """`User.phone` is stored E.164, but normalize anyway: a row predating that
    rule, or one written by a fixture, would otherwise silently fail to match
    an allowlist entry that is correct."""
    from accounts.phone import normalize
    return normalize(getattr(user, 'phone', '') or '') or ''


def _allowlist() -> set:
    """Normalized phones the board is restricted to, or an empty set.

    **Empty means EVERYONE, not nobody.**  `ANDROID_BOARD` is the feature
    switch; this is a narrowing on top of it, and a narrowing that defaulted to
    nobody would make `ANDROID_BOARD=1` on its own do nothing at all -- the
    "shipped, tested and unreachable" failure this codebase has already hit
    twice (the casual receipt no round could open, and the setup-edit button
    gated on the rule it replaced).  A switch that silently does nothing is
    worse than one that does the whole thing, because the whole thing is at
    least visible.

    The cost of that choice is that turning the feature on without also
    setting this reaches every Android phone following any round with a board.
    That is the documented behaviour rather than a trap, and it is why the
    Configuration note says to set both in one change.

    Phones rather than user ids, following `accounts/otp.py`
    `_review_bypass_phones`: the phone is the identity the whole app already
    matches on, and it is a value you know rather than one you look up.
    Normalized on both sides, so a pasted `(510) 282-3126` works.
    """
    from accounts.phone import normalize
    out = set()
    for part in (os.environ.get('ANDROID_BOARD_PHONES', '') or '').split(','):
        n = normalize(part.strip())
        if n:
            out.add(n)
    return out


def _tag(round_obj) -> str:
    """One row per ROUND, not per foursome.

    The tag is what makes the board replace itself.  Keying it on the foursome
    would give a TD watching a multi-group tournament one row per group, each
    claiming to be the board; keying it on the game would start a second row
    the moment a round's primary changed.
    """
    return f'halved-board-{round_obj.id}'


def _joined(*parts, sep=' · ') -> str:
    """Join the non-empty parts only.

    Every slot on a card is optional and several are empty for most of a round
    (the money line is blank from the 1st to the 17th on a match card).  A
    separator with nothing on one side of it reads as a missing value rather
    than as a slot that does not apply.
    """
    return sep.join(p for p in (_squash(s) for s in parts) if p)


def _squash(s) -> str:
    """One string, single-spaced.

    `group_stroke_band` emits a DELIBERATE double space after its label -- its
    docstring says so: the label is a separate span drawn at reduced opacity,
    and the gap is what separates the spans on a build that has not learnt the
    layout.  **That is correct there and must not be "fixed" in the registry**,
    which draws two spans.  It is wrong only here, where a notification is one
    run of text and the gap reads as a hole in it.
    """
    return ' '.join((s or '').split())


def _sides_lines(state) -> list:
    out = []
    for s in (state.get('sides') or []):
        names = (s.get('names') or '').strip()
        if not names:
            continue
        note = (s.get('note') or '').strip()
        out.append(f'{names} — {note}' if note else names)
    return out


def _title(state, *, final) -> str:
    """The headline and the state slot, or the settlement on a closing frame.

    Three things go wrong flattening this that do not go wrong on the card,
    and all three were found by rendering the real fleet rather than fixtures:

    * **Sixes sends `—` as its state word** once a segment is done. A dash
      between two middots reads as a missing value.
    * **Rabbit sends the same string twice** — `number.text` and
      `state.word` are both `LOOSE` while the rabbit is loose, which the card
      draws in two different places and one line prints as `LOOSE · LOOSE`.
    * **Nassau empties all three** on a finished round. The card still reads
      because its header and sides rows carry it; an Android notification with
      no title renders as the app name alone, which reads as a fault rather
      than as a round that has ended.

    So: placeholders dropped, repeats dropped, and the header as the floor.
    """
    fin = state.get('final') or {}
    if final and fin.get('amount'):
        return _joined(fin.get('amount'), fin.get('detail'))

    st    = state.get('state') or {}
    parts, seen = [], set()
    for raw in ((state.get('number') or {}).get('text'),
                st.get('word'), st.get('to_play')):
        part = (raw or '').strip()
        if _blank(part) or part.casefold() in seen:
            continue
        seen.add(part.casefold())
        parts.append(part)
    if parts:
        return _joined(*parts)

    hdr = state.get('header') or {}
    return _joined(hdr.get('game'), hdr.get('segment'))


def notification_text(state, *, final=False) -> dict:
    """Flatten a card's state into `{title, body, lines}`.

    Pure, and tested as such — it is the only part of this module that makes
    judgements, and the judgements are about what survives truncation.

    `title` is the headline and the state slot: the glance, and the only thing
    guaranteed to be read.  On a closing frame the settlement outranks both.

    `body` is ONE line, because one line is all the system draws.  Ordered
    identify -> stroke warning -> locate -> money.  The ribbon sits second
    rather than last because it only appears on a hole where the reader
    actually gets a stroke, so the width it costs is width that matters; when
    it is absent nothing moves.

    `lines` is the whole board for a client that can render it, ordered so that
    a renderer clipping from the bottom loses the least.
    """
    state = state or {}
    fin   = state.get('final') or {}
    hdr   = state.get('header') or {}

    game    = _squash(hdr.get('game'))
    segment = _squash(hdr.get('segment'))
    head    = _joined(game, segment)
    ribbon  = _squash(state.get('ribbon'))
    thru    = _squash(state.get('thru'))
    money   = _squash((state.get('footer') or {}).get('money'))
    ctx     = _squash((state.get('footer') or {}).get('context'))
    tee     = _squash(state.get('tee'))

    # A card that signs off with a settlement says so; one that keeps its board
    # (Rabbit, Survivor, Stableford, Triple Cup) has an empty `final` and falls
    # through to the running slots, which is what those frames are for.
    title = _title(state, final=final)

    # **The body is ordered by what it costs to lose**, because the system
    # truncates it and the tail is the part nobody reads:
    #
    #   ribbon   only present on a hole where the reader actually strokes, so
    #            the width it takes is width that matters
    #   money    the point of the game, and the first thing asked about
    #   segment  the card's own "where are we" corner — hole/par/yards, or the
    #            round state (`ZOMBIE \u00b7 ROUND COMPLETE`)
    #   thru     locates the reader
    #   game     the label, and the only one of the five the reader can infer
    #            from the title and from being in the round at all
    #
    # Deduped against the title's own parts: the title falls back to the header
    # on a card that empties its headline slots (Nassau, once the round is
    # over), and a body restating it is a notification that says one thing
    # twice.
    taken = {p.casefold() for p in title.split(' \u00b7 ')}
    body  = _joined(*[p for p in (ribbon, money, segment, thru, game)
                      if p.casefold() not in taken])

    lines = [head, ribbon]
    lines += _sides_lines(state)
    lines += [thru, money]
    if final:
        lines.append((fin.get('collect') or '').strip())
    lines += [ctx, tee]

    # Seeded with the title: a rich client draws the title and then these, so a
    # line repeating it is noise — which is exactly what the header becomes on
    # the Nassau card that has nothing else to put up there.
    seen, ordered = {title}, []
    for ln in lines:
        ln = (ln or '').strip()
        # A card can legitimately put the same string in two slots (Skins'
        # closing frame carries the winners in both `sides` and `collect`), and
        # one repeated line looks like a rendering fault rather than emphasis.
        if ln and not _blank(ln) and ln not in seen:
            seen.add(ln)
            ordered.append(ln)

    return {'title': title, 'body': body, 'lines': ordered[:MAX_LINES]}


def _android_options(round_obj) -> dict:
    """Plain-dict delivery options, resolved into an `AndroidConfig` inside
    `services.push`.

    A dict rather than the firebase-admin object so `firebase_admin` stays
    confined to the one module that already owns the credentials — importing it
    here would make this module unimportable on a machine without the package,
    including CI.
    """
    tag = _tag(round_obj)
    return {
        'tag': tag,
        # Four distinct collapse keys are retained per device; sharing the tag
        # means a phone that was off through three holes wakes to the current
        # board rather than to a queue of superseded ones.
        'collapse_key': tag,
        'channel_id': BOARD_CHANNEL,
        # Not urgency for its own sake: `normal` may be batched under Doze, and
        # a board that arrives two holes late is wrong rather than slow.  This
        # is message priority, not channel importance — it does not create a
        # heads-up banner.
        'priority': 'high',
    }


def push_round_android(round_obj, *, final=False) -> int:
    """Send the current board to every Android phone following this round.

    Returns the number of golfers written to.  Mirrors
    `live_activity_push.push_round` deliberately, including building the state
    per recipient: everything on the card is the same string on every phone
    except the money line, and that one is the reason this is a loop.
    """
    if not is_enabled():
        return 0

    from accounts.models import DeviceToken
    from services.live_activity_registry import activity_state, board_recipients
    from services.push import category_enabled, send_push

    user_ids = board_recipients(round_obj)
    if not user_ids:
        return 0

    # The intersection is the recipient list: a follower with no Android device
    # is served by the iOS card, and an Android device belonging to nobody who
    # can read this round is not a recipient at all.
    by_user = {}
    for d in (DeviceToken.objects
              .filter(platform='android', user_id__in=user_ids)
              .select_related('user')):
        by_user.setdefault(d.user, []).append(d.token)
    if not by_user:
        return 0

    allow   = _allowlist()
    options = _android_options(round_obj)
    sent, dead = 0, set()

    for user, tokens in by_user.items():
        # Before `activity_state`, which is the expensive call: a trial
        # restricted to one phone should not cost a summary per golfer.
        if allow and _normalized_phone(user) not in allow:
            continue
        if not category_enabled(user, CATEGORY):
            continue
        try:
            state = activity_state(round_obj, user, final=final)
            if not state:
                continue
            text = notification_text(state, final=final)
            data = {
                'type'    : CATEGORY,
                'round_id': str(round_obj.id),
                'kind'    : state.get('kind') or '',
                # The rich board, for a client that can draw it. Newline-joined
                # because every FCM data value is a string.
                'lines'   : '\n'.join(text['lines']),
            }
            dead |= send_push(tokens, text['title'], text['body'], data,
                              android=options)
            sent += 1
        except Exception:  # pragma: no cover - one bad row never stops the rest
            logger.exception('android board: round %s user %s',
                             round_obj.id, user.id)

    if dead:
        DeviceToken.objects.filter(token__in=dead).delete()
    return sent
