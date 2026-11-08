"""Finish round -> a frozen Receipt — settle-up handoff step 3.

Three things happen when the scorer taps Finish round: the money is FROZEN
into a :class:`tournament.models.Receipt`, the golfers who are on Halved get a
push, and the scorer is handed Round over.  This module does the first two.

**Casual rounds only, and that is the handoff's own division.**  §4 puts the
tournament receipt under Group C: "one receipt for the WHOLE FIELD, with
several pots", built when the TD settles rather than when a round ends, and it
says in as many words that foursome side bets "settle in the group and are not
on this receipt".  A per-round hook cannot produce that document, so a
tournament round is skipped here and waits for the Group C assembler.

**A round that settles to nothing gets no receipt.**  Everyone square, or a
game that ran and paid nobody, would produce four "+$0 to collect" lines and a
link saying nothing.  The casual receipt payload already refuses that case and
this keeps the rule in one place.

**One receipt per settling, and the CALLER is what makes that true.**
`RoundCompleteView` reaches this only on the status flip, so a second tap of
Finish round never settles twice.  A round REOPENED and re-settled is a
different matter and gets a NEW code — see the model, which keeps the old link
saying what the golfers were shown.  Do not add an "already has one" guard
here: it reads like idempotency and is really a refusal to re-settle.

**The per-game rows are a seam, not a stub.**  §4 gives every game its own
summary language ("Kim 4 · Lipkin 2 · Reid 1"), which is steps 4 to 6.
:data:`GAME_SUMMARY` is where those land; until a game registers one it falls
back to naming who the money moved to, which is true and useful rather than a
placeholder that says nothing.
"""
from __future__ import annotations

import logging

from django.db import transaction
from django.utils import timezone

from services.settle_up import Transfer, classify_recipients, for_display, settle
from services.settlement import round_settlement
from services.settlement_receipt import money

logger = logging.getLogger(__name__)

#: ``{game_key: callable(round_obj, per_game_entry, names) -> [[label, value]]}``
#: Registering one here is the ONLY thing a game has to do to get its own
#: language onto every receipt surface at once.
#:
#: It returns a LIST because §4's summaries are not all one row: Sequoya 3s
#: states its matches and its bets separately, and Banker gives every golfer a
#: line of his own.
GAME_SUMMARY: dict = {}

#: ``{game_key: callable(round_obj, per_game_entry, names) -> [Section]}`` for
#: §3's ``detail`` — the LONG form, which appears on the web receipt only.
#:
#: §1 is explicit about where it goes: the web receipt "uses ``webGames`` when
#: present", while Round over and the preview image get the short ``games``
#: rows.  The ticket is width-constrained and the web page is the document
#: people keep, so a per-match or per-hole breakdown belongs there and nowhere
#: else.
#:
#: A Section is ``{'label': str, 'rows': [[label, value], ...]}``.  The label
#: NAMES THE GAME ("Sixes · the matches"), because a round playing two games
#: puts two detail sections on one page and "The matches" alone would not say
#: whose.
GAME_DETAIL: dict = {}

#: ``{game_key: callable(round_obj, player_ids) -> {player_id: str}}`` for §3's
#: caption override.  The default is "{gross} · net {net}"; a game whose unit
#: is not strokes says so here ("9 pts · v. target +3", "banked 4 · bet +$290").
GAME_CAPTION: dict = {}

#: Like :data:`GAME_CAPTION`, but for the PREVIEW's shorter chip (§3's
#: ``imageCaption``).  A separate dict rather than a tuple return, because the
#: two are different sentences for different widths and a union type is how
#: one quietly ends up rendered in the other's slot.
GAME_IMAGE_CAPTION: dict = {}

#: ``{game_key: callable(round_obj) -> str}`` for §3's ``stakeLabel``
#: ("$10 a match", "$2 a skin"), which composes the ``sub`` line.
GAME_STAKE: dict = {}

#: ``{game_key: callable(round_obj, player_ids) -> {player_id: (text, tone)}}``
#: — a golfer's RESULT in that game, for a round played for fun.  A third
#: element may carry the caption, for the reason below.
#:
#: There is no money on such a round, so the chip that normally holds a figure
#: holds this instead ("1 UP", "2nd", "41 pts", "4 skins") and the caption
#: appends the side games'.  One registry serves both, because they are the
#: same sentence at two widths: what this golfer did in this game.
#:
#: ``tone`` is ``'up'``, ``'dn'`` or ``'ev'``, and the two kinds of game
#: answer it differently ON PURPOSE.  A match game has a real direction, so
#: it reports up or down.  A COUNTING game does not: second of four is
#: neither a win nor a loss, and in a round played for nothing there is no
#: loss to report — so the leader reads up and everybody else reads level,
#: rather than colouring three golfers red for a game nobody staked.
#:
#: **A game whose chip is a PLACE must also state the figure it placed on**,
#: which is what the optional third element is for.  The default caption is
#: the round's gross and net, and the round's net is not necessarily the one
#: the game ranked: a Stroke Play round scored GROSS put "1st" over a net of
#: 54 while the golfer captioned "net 53" read "3rd" — both correct, and
#: together unreadable.  A figure has to be comparable with the one beside
#: it, so a game that ranks on its own basis says what that basis was.
GAME_RESULT: dict = {}

#: How many golfers the unformatted fallback row names before collapsing.
#: Four is a full group, which is the common case it must not truncate.
_FALLBACK_MOVERS = 4

#: Per golfer, the most an imbalance can be and still be rounding.
_MAX_ROUNDING_CENTS = 1


def _cents(dollars) -> int:
    """Money arrives from the engines in dollars and settles in cents (§2.1).

    ``round`` rather than ``int``: 26.0 is sometimes 25.999999 by the time a
    float has been through a payout split, and truncating it loses a cent that
    then fails the sum-to-zero assert with no explanation.
    """
    return int(round(float(dollars or 0) * 100))


def _date_label(round_obj) -> str:
    # "Nov 4", the handoff's own format.
    return round_obj.date.strftime('%b %-d') if round_obj.date else ''


def _sub(round_obj, games: list, *, for_fun: bool = False) -> str:
    """"Tilden Park GC · Nov 4 · $10 a match · $2 a skin" (§3).

    For fun it ends "· for fun", which is the whole of what the stake slot has
    to say when there is no stake.
    """
    parts = [round_obj.course.name, _date_label(round_obj)]
    if for_fun:
        return ' · '.join([p for p in parts if p] + ['for fun'])
    for entry in games:
        fn = GAME_STAKE.get(entry['game'])
        label = fn(round_obj) if fn else None
        if label:
            parts.append(label)
    if len(parts) == 2 and round_obj.bet_unit:
        # No game has registered a stake label, so the UNIT is not known here.
        # §3's labels name it ("$2 a skin", "$10 a match") and a generic
        # fallback that guessed would print "$5 a point" on a skins round —
        # true of the figure and false of the game.  The bare stake is the
        # most that can be said without a formatter.
        parts.append(f'{money(round_obj.bet_unit)} stake')
    return ' · '.join(p for p in parts if p)


def _for_fun(round_obj, per_game: list) -> bool:
    """Is nothing in this round played for money?

    Asked of :data:`GAME_STAKE` rather than of a flag, because that registry
    is already the one place a game says what it is played for — the app's
    own "Play for fun — no stakes" control simply sets the stake to zero, so
    a round is for fun exactly when every stake is.

    **A game with no stake formatter means NO**, not yes.  An unknown stake
    is unknown, and claiming "for fun" over real money would print RESULTS on
    a round somebody is owed money from.  Failing the other way costs only
    today's behaviour: no receipt.

    **Every ACTIVE game is asked, not only the ones that settled.**  Honors
    carries its own stake and is not in `settlement.NETTABLE`, so it never
    reaches `per_game` — asking only the settled games would call a round
    with free Stroke Play and a staked Honors "for fun", in the `sub` line,
    on a document headed RESULTS.
    """
    games = {e['game'] for e in per_game} | set(round_obj.active_games or [])
    for game in sorted(games):
        fn = GAME_STAKE.get(game)
        if fn is None:
            return False
        try:
            if fn(round_obj):
                return False
        except Exception:
            logger.exception('receipt: %s stake failed', game)
            return False
    # A round-level stake counts even where no game reads it: it is a figure
    # somebody typed, and a round carrying one is not being played for fun.
    return not round_obj.bet_unit


def _results(round_obj, per_game: list, order: list) -> tuple:
    """``({pid: (text, tone)}, {pid: [clause]}, {pid: caption}, [pid])``.

    The fourth is the order to draw them in: the primary game's ranking.

    The chip is the PRIMARY game's result and the caption carries the side
    games', which is §"Play for fun"'s own split: "1 UP", captioned
    "88 · net 76 · 4 skins".
    """
    from services.live_activity_registry import primary_game

    primary = primary_game(round_obj)
    by_game = {}
    for entry in per_game:
        fn = GAME_RESULT.get(entry['game'])
        if not fn:
            continue
        try:
            rows = fn(round_obj, order) or {}
        except Exception:
            logger.exception('receipt: %s result failed', entry['game'])
            continue
        # A formatter may return (text, tone) or (text, tone, caption).
        by_game[entry['game']] = {
            pid: (tuple(v) + ('',))[:3] for pid, v in rows.items()}

    chips = dict(by_game.get(primary) or {})
    # Whatever the round calls primary, SOMETHING has to fill the chip: a
    # for-fun receipt whose chips were blank would be a document with no
    # result on it at all.  The first game that can answer does.
    if not chips:
        for entry in per_game:
            if by_game.get(entry['game']):
                primary = entry['game']
                chips = dict(by_game[primary])
                break

    sides = {}
    for entry in per_game:
        if entry['game'] == primary:
            continue
        for pid, (text, _tone, _cap) in (by_game.get(entry['game']) or {}).items():
            if text:
                sides.setdefault(pid, []).append(text)

    basis = {pid: cap for pid, (_t, _tn, cap) in chips.items() if cap}
    # **The formatter's own order is the game's RANKING** — `stroke_play`
    # iterates its ranked results, the counting games sort by count — so the
    # chips are ordered by it rather than by the round's seating.  Sorting by
    # tone alone left a document reading 1st, 3rd, 3rd, 2nd.
    ranked = [pid for pid in chips if pid in order]
    ranked += [pid for pid in order if pid not in chips]
    return ({pid: (t, tn) for pid, (t, tn, _c) in chips.items()},
            sides, basis, ranked)


def _is_money(value) -> bool:
    return '$' in str(value)


def _no_money(sections: list) -> list:
    """Every row naming money dropped, and any section it leaves empty.

    **No figure on a for-fun document is money.**  Several formatters state
    one — Banker gives every golfer a banked/betting pair, the group pools say
    "$12 each", and every `GAME_DETAIL` section carries a column of it — and
    on a round played for nothing those all read "$0".  That is precisely the
    "four +$0 lines say nothing" failure the refusal in `build_round_receipt`
    exists to prevent, arriving by the other door and on the one surface
    golfers actually read.

    Rows rather than whole sections, so a section that is not about money
    survives whole: Sixes' matches ("2 · holes 5–10 · Halved") say the same
    thing whether or not anybody staked them.
    """
    out = []
    for sec in sections:
        rows = [r for r in sec.get('rows') or [] if not _is_money(r[1])]
        if rows:
            out.append({**sec, 'rows': rows})
    return out


def _result_rows(round_obj, per_game: list, names: dict, order: list) -> list:
    """The games section for a round played for fun.

    `_summary_rows`' own formatters describe where the MONEY went.  Several
    say nothing at all without a pot — Stroke Play's returns no row by
    design — and several state a figure, which on this document would be a
    zero.  Either way the game states its RESULT instead; a formatter whose
    row is about something else (Nassau's margin, Sixes' "Settled 3 of 3")
    is kept as it is.
    """
    rows = []
    for entry in per_game:
        fn = GAME_SUMMARY.get(entry['game'])
        made = []
        if fn:
            try:
                made = fn(round_obj, entry, names) or []
            except Exception:
                logger.exception('receipt: %s summary failed', entry['game'])
        # The game states its RESULT instead — see `_no_money`, which is the
        # same rule the long form is held to.
        if any(_is_money(value) for _label, value in made):
            made = []
        if made:
            rows.extend(made)
            continue
        fn = GAME_RESULT.get(entry['game'])
        if not fn:
            continue
        try:
            got = fn(round_obj, order) or {}
        except Exception:
            logger.exception('receipt: %s result failed', entry['game'])
            continue
        # The formatter's order, same as the chips — see `_results`.
        ranked = [pid for pid in got if pid in order and (got[pid] or ('',))[0]]
        if not ranked:
            continue
        rows.append([entry['label'], ' · '.join(
            f'{_short(names, pid)} {got[pid][0]}' for pid in ranked)])
    return rows


def _summary_rows(round_obj, per_game: list, names: dict) -> list:
    rows = []
    for entry in per_game:
        fn = GAME_SUMMARY.get(entry['game'])
        if fn:
            try:
                for row in fn(round_obj, entry, names) or []:
                    rows.append(list(row))
                continue
            except Exception:
                # A formatter is presentation. If one breaks, the round still
                # settles and the money is still right — the fallback below
                # says who it moved to.
                logger.exception('receipt: %s summary failed', entry['game'])
        # Fallback: who the money moved to, biggest first. True, checkable,
        # and replaced the moment that game registers its own language.
        #
        # It COLLAPSES rather than truncating. Capping at three put "Tim +$32
        # · Paul +$8 · ST −$20" on a four-ball and dropped the fourth golfer
        # with nothing saying so, which reads as a bug rather than as a
        # summary — the same rule the preview's "13 more" follows.
        movers = sorted(((pid, net) for pid, net in entry['nets'].items()
                         if _cents(net)), key=lambda kv: -kv[1])
        shown, rest = movers[:_FALLBACK_MOVERS], movers[_FALLBACK_MOVERS:]
        value = ' · '.join(
            f'{_short(names, pid)} {money(net, sign=True)}'
            for pid, net in shown)
        if rest:
            value += f' · {len(rest)} more'
        rows.append([entry['label'], value or 'no money moved'])
    return rows


def _detail_sections(round_obj, per_game: list, names: dict) -> list:
    """Every registered game's long-form sections, in the round's game order.

    A game with no formatter contributes nothing — there is no useful generic
    detail, and the summary row above it already says who the money moved to.
    So an unregistered game simply has no extra section rather than a section
    saying nothing.
    """
    out = []
    for entry in per_game:
        fn = GAME_DETAIL.get(entry['game'])
        if not fn:
            continue
        try:
            for section in fn(round_obj, entry, names) or []:
                rows = [list(r) for r in (section.get('rows') or [])]
                if rows:
                    out.append({'label': section['label'], 'rows': rows})
        except Exception:
            # Detail is presentation. A broken formatter costs the long form,
            # never the receipt: the money is already settled above it.
            logger.exception('receipt: %s detail failed', entry['game'])
    return out


def _captions(round_obj, player_ids) -> dict:
    """§3's default caption, "{gross} · net {net}".

    Read from the stored scorecard rather than recomputed: this is a frozen
    document, and a caption that disagreed with the card it was taken from
    would be the one thing a golfer checks it against.
    """
    from django.db.models import Count, Sum
    from scoring.models import HoleScore
    rows = (HoleScore.objects
            .filter(foursome__round=round_obj, player_id__in=player_ids,
                    gross_score__isnull=False)
            .values('player_id')
            .annotate(gross=Sum('gross_score'), net=Sum('net_score'),
                      holes=Count('id')))
    out = {}
    for r in rows:
        if not r['holes']:
            continue
        out[r['player_id']] = (f'{r["gross"]} · net {r["net"]}'
                               if r['net'] is not None else f'{r["gross"]}')
    return out


def _load_formatters():
    """Import the per-game formatters so they register themselves.

    Done here rather than at module import because they import the game
    services, which import models — and this module is imported from
    ``api.views`` at request time, where a circular import would be a 500 on
    Finish round rather than a missing row.
    """
    try:
        import services.receipt_games  # noqa: F401
    except Exception:
        logger.exception('receipt: formatters failed to load')


def build_round_receipt(round_obj, *, scorer=None):
    """Freeze this round's money into a Receipt.  ``None`` when there is none.

    Never raises: Finish round must close the round whatever happens to the
    receipt.  A golfer whose round would not finish because a document could
    not be composed is a worse failure than a missing link.
    """
    from tournament.models import Receipt
    _load_formatters()
    try:
        if round_obj.tournament_id:
            return None                       # Group C, at tournament settle
        # **A receipt is minted when the MONEY CHANGES, and not otherwise.**
        # See `_same_money` below — the comparison, and why it is this rule
        # rather than a guard on an existing row or on the round's status.

        data = round_settlement(round_obj, min_games=1)
        if not data:
            return None
        per_game = data.get('per_game') or []
        players = data.get('players') or []
        if not per_game or not players:
            return None

        names = {p['player_id']: p for p in players}
        order = [p['player_id'] for p in players]

        # §2.2: a round playing more than one game settles ONCE, on the sum.
        nets = {pid: 0 for pid in order}
        for entry in per_game:
            for pid, net in entry['nets'].items():
                if pid in nets:
                    nets[pid] += _cents(net)

        # **A round played for fun still gets a document, and that is the
        # point of it.**  Its nets are all zero, so the money rule below would
        # refuse one — but §"Play for fun" turns the receipt into RESULTS and
        # says why it must still be built: "the results link is the invite".
        # Before this, finishing such a round produced no Round over, no link
        # and no text at all.
        for_fun = _for_fun(round_obj, per_game)

        if not for_fun and not any(nets.values()):
            # Everyone square at a REAL stake is a different thing: the money
            # was played for and nobody won it, and four "+$0" lines say
            # nothing.  That refusal stands.
            return None

        drift = sum(nets.values())
        if drift:
            # The engines round per game in dollars, so a multi-game round can
            # land a cent out. Absorb it on the biggest winner rather than
            # failing the settle: a receipt that cannot be built is worse than
            # one cent, and it is visible in the chips either way.
            #
            # **Bounded, because not every imbalance is rounding.** A POOL
            # whose payout table does not pay out the pool is out by real
            # money — a 40 Balls round collecting $120 and paying $80 is $40
            # short — and absorbing that would hand one golfer a figure
            # nobody agreed to, silently. A cent a golfer is the most that
            # can be rounding; past that the round says so by having no
            # receipt rather than a wrong one.
            if abs(drift) > len(order) * _MAX_ROUNDING_CENTS:
                logger.error(
                    'receipt: round %s is out by %s cents across %s golfers — '
                    'refusing rather than absorbing it', round_obj.id, drift,
                    len(order))
                return None
            nets[order[0]] -= drift

        transfers = for_display(settle(nets, order=order))
        captions = _captions(round_obj, order)
        chips = ranked = None

        if for_fun:
            chips, sides, basis, ranked = _results(round_obj, per_game, order)
            summary_rows = _result_rows(round_obj, per_game, names, order)
            # The default gross-and-net, overridden where the primary game
            # ranks on its own basis — see GAME_RESULT on why the two have to
            # be comparable — then the side games appended.
            #
            # A game's own `GAME_CAPTION` is deliberately NOT applied: those
            # describe the money ("banked 4 · bet +$290"), and Stroke Play's
            # captions a PLACE, which the chip beside it already carries.
            captions.update(basis)
            for pid, extra in sides.items():
                base = captions.get(pid, '')
                captions[pid] = ' · '.join([base] + extra) if base \
                    else ' · '.join(extra)
            # The preview takes the same caption: its shorter override is a
            # money-side sentence, and there is no money here.
            image_captions = {}
        else:
            summary_rows = _summary_rows(round_obj, per_game, names)
            for entry in per_game:
                fn = GAME_CAPTION.get(entry['game'])
                if not fn:
                    continue
                try:
                    captions.update({k: v for k, v in
                                     (fn(round_obj, order) or {}).items() if v})
                except Exception:
                    logger.exception('receipt: %s caption failed',
                                     entry['game'])
            image_captions = {}
            for entry in per_game:
                fn = GAME_IMAGE_CAPTION.get(entry['game'])
                if not fn:
                    continue
                try:
                    image_captions.update(
                        {k: v for k, v in
                         (fn(round_obj, order) or {}).items() if v})
                except Exception:
                    logger.exception('receipt: %s image caption failed',
                                     entry['game'])

        def _chip(pid):
            row = {'golferId': pid,
                   'name': names[pid].get('short_name') or names[pid]['name'],
                   'caption': captions.get(pid, ''),
                   'imageCaption': image_captions.get(pid, '')}
            if for_fun:
                text, tone = chips.get(pid, ('', 'ev'))
                row['net'] = text
                row['tone'] = tone
            else:
                row['net'] = nets[pid]
            return row

        if for_fun:
            # Every net is zero, so there is nothing to rank by here: the
            # primary game's own ranking is the order, with anyone it does not
            # place keeping the round's.  Deterministic, which a frozen
            # document has to be.
            chip_order = ranked
        else:
            chip_order = sorted(order, key=lambda p: -nets[p])

        payload = {
            'title': ' + '.join(e['label'] for e in per_game),
            'sub': _sub(round_obj, per_game, for_fun=for_fun),
            'nets': [_chip(pid) for pid in chip_order],
            # §"Play for fun": omitted, so the renderers drop the whole block
            # rather than heading an empty one.
            'pays': [] if for_fun else [
                {'from': _short(names, t.frm), 'to': _short(names, t.to),
                 'amount': t.amount} for t in transfers],
            # Empty means no section, not a heading over nothing — the same
            # rule `_ssec` applies to every detail section.
            'games': ([{'label': 'The games', 'rows': summary_rows}]
                      if summary_rows else []),
            'scorer': _scorer_block(scorer),
            'settledAt': timezone.now().isoformat(),
        }
        if for_fun:
            payload['forFun'] = True
        # §3: `webGames` REPLACES `games` on the web, so it carries the short
        # form too — not just the extra sections. Set only when there is
        # something extra to say; the renderer already falls back to `games`,
        # and a key identical to it is noise in a stored payload.
        detail = _detail_sections(round_obj, per_game, names)
        if for_fun:
            detail = _no_money(detail)
        if detail:
            payload['webGames'] = (
                [{'label': 'The games', 'rows': summary_rows}] + detail)

        recipients = _recipients(round_obj, order, names, scorer)
        payload['recipients'] = {'push': recipients.push,
                                 'text': recipients.text,
                                 'none': recipients.none}
        payload['note'] = recipients.note

        # Nothing new to say: hand back the receipt the golfers already have
        # rather than a second code for the same figures.
        previous = Receipt.objects.filter(round=round_obj).first()
        if previous and _same_money(previous.payload, payload):
            return previous

        receipt = Receipt.objects.create(
            round=round_obj, payload=payload, scorer=scorer,
            settled_at=timezone.now())
        receipt.payload['code'] = receipt.code
        receipt.save(update_fields=['payload'])
        return receipt
    except Exception:
        logger.exception('receipt: could not build for round %s', round_obj.id)
        return None


#: The parts of a payload that ARE the document.  Everything else —
#: `settledAt`, `code`, who pressed the button, who it is being sent to — is
#: about this particular settling rather than about the money.
_MATERIAL = ('title', 'sub', 'nets', 'pays', 'games', 'webGames', 'forFun')


def _same_money(a: dict, b: dict) -> bool:
    """Do these two payloads say the same thing to the golfers?

    **This is what decides whether a second Finish round mints a new code**,
    and the rule took three goes to get right, so it is worth the words.

    Guarding on "a receipt already exists" refused to RE-SETTLE: a round
    reopened to fix a score was handed back its original payload with no way
    to re-freeze it.

    Guarding in the CALLER instead — only settling on the status flip —
    looked correct because a double tap cannot flip twice.  It was wrong
    about the case that actually happened (Tilden, 7 Nov 2026): Finish round
    was slow, the first tap settled while the last five holes were still in
    the phone's sync queue, and the second tap found the round already
    complete and did nothing.  Four golfers were left with a receipt stamped
    Final whose every figure was $10 out — it said "Settled 2 of 4" about a
    finished round.  **A second tap is the scorer asking again, usually
    because something has arrived since.**

    So neither: settle every time, and mint only when the answer differs.
    A double tap returns the same receipt, a re-settle after more scores
    returns a new one, and two completes racing each other compute the same
    payload so only one row is written — which the old comment here called
    benign and was not.
    """
    return all((a or {}).get(k) == (b or {}).get(k) for k in _MATERIAL)


def _short(names: dict, pid) -> str:
    entry = names.get(pid) or {}
    return entry.get('short_name') or entry.get('name') or ''


def _scorer_block(scorer) -> dict:
    if not scorer:
        return {}
    name = scorer.name or ''
    initials = ''.join(part[0] for part in name.split()[:2]).upper()
    return {'name': name, 'initials': initials}


def _recipients(round_obj, order, names, scorer):
    """§2.5, against this round's real roster."""
    from accounts.phone import normalize
    from core.models import Player
    from django.contrib.auth import get_user_model

    players = {p.id: p for p in Player.objects.filter(id__in=order)}
    phones = {normalize(p.phone) for p in players.values() if p.phone}
    phones.discard(None)
    on_app = set(get_user_model().objects
                 .filter(phone__in=phones)
                 .values_list('phone', flat=True))
    golfers = []
    for pid in order:
        p = players.get(pid)
        if not p:
            continue
        phone = normalize(p.phone) if p.phone else None
        golfers.append({
            'id': pid,
            'name': _short(names, pid),
            'on_halved': bool(p.user_id) or bool(phone and phone in on_app),
            'mobile': p.phone or '',
        })
    return classify_recipients(golfers, scorer.id if scorer else None)


# --------------------------------------------------------------------------
# §1 — the push, for the golfers who are on Halved
# --------------------------------------------------------------------------

def receipt_url(code: str) -> str:
    base = (getattr(__import__('django.conf', fromlist=['settings']).settings,
                    'PUBLIC_BASE_URL', '') or '').rstrip('/')
    return f'{base}/r/{code}/'


def notify_receipt(receipt) -> int:
    """One push each, per §1.  Returns how many golfers were reached.

    **The body is per golfer, which is why this is not
    ``notify_round_event``.**  That helper sends one title and body to every
    follower of a round; §1 tells a winner what he won ("You won $26 · View
    receipt") and everybody else only where it was ("Tilden Park GC · View
    receipt").  A shared body would have to pick one of those and be wrong for
    somebody.

    **Only golfers on the receipt, never watchers.**  A spectator did not play
    for anything, so a push about money is addressed to the wrong person — and
    ``users_for_round`` deliberately includes watchers.

    **Its own category.**  Muting round-complete should not mute the money:
    they are different facts, and this is the one a golfer is waiting for.

    Best-effort and never raises: the round is already closed by the time this
    runs, and a notification problem must not undo that.
    """
    try:
        from accounts.models import DeviceToken, SentNotification
        from core.models import Player
        from services.push import send_push, tokens_for_users

        payload = receipt.payload or {}
        push_ids = (payload.get('recipients') or {}).get('push') or []
        if not push_ids:
            return 0
        by_id = {n['golferId']: n for n in payload.get('nets') or []}
        course = (receipt.round.course.name if receipt.round_id else '')
        url = receipt_url(receipt.code)
        for_fun = bool(payload.get('forFun'))
        # §"Play for fun": one line for everyone, and NO win-or-loss wording.
        # Nobody won anything, so there is no figure to name — and a push
        # saying somebody did would be about a round that was not played for
        # it.  The title changes with it: nothing was settled.
        title = 'Round over' if for_fun else 'Settled'

        sent = 0
        for player in Player.objects.filter(id__in=push_ids).select_related('user'):
            user = player.user or _user_for_phone(player.phone)
            if not user:
                continue
            key = f'receipt:{receipt.code}:player={player.id}'
            _, created = SentNotification.objects.get_or_create(
                dedup_key=key, defaults={'event_type': 'receipt'})
            if not created:
                continue
            net = (by_id.get(player.id) or {}).get('net', 0) or 0
            if for_fun:
                body = f'{course} · View results'
            else:
                # §1: won -> name the figure; lost or level -> name the place.
                # Telling a man who lost $18 that he "won −$18" is the obvious
                # trap, and naming the course is what makes the other push
                # useful to somebody who played two rounds this week.
                body = (f'You won {money(net / 100)} · View receipt'
                        if isinstance(net, (int, float)) and net > 0
                        else f'{course} · View receipt')
            tokens = tokens_for_users([user], 'receipt')
            if not tokens:
                continue
            dead = send_push(tokens, title, body, {
                'type': 'receipt', 'code': receipt.code, 'url': url,
                'round_id': str(receipt.round_id or ''),
            })
            if dead:
                DeviceToken.objects.filter(token__in=dead).delete()
            sent += 1
        return sent
    except Exception:  # pragma: no cover - defensive
        logger.exception('receipt: push failed for %s', receipt.code)
        return 0


def _user_for_phone(phone):
    if not phone:
        return None
    from accounts.phone import normalize
    from django.contrib.auth import get_user_model
    norm = normalize(phone)
    if not norm:
        return None
    return get_user_model().objects.filter(phone=norm).first()


def settle_round(round_obj, *, scorer=None):
    """The whole Finish round hook: freeze, then push after the commit.

    The push is deferred to ``on_commit`` so a rolled-back completion cannot
    tell four golfers the money is settled — the same rule the activity feed
    follows, and for the same reason.
    """
    receipt = build_round_receipt(round_obj, scorer=scorer)
    if receipt:
        transaction.on_commit(lambda: notify_receipt(receipt))
    return receipt
