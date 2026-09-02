"""
services/live_activity_match.py
-------------------------------
The match-play lock screen — singles and fourball
(docs/design-review/handoff-live-activities/match-HANDOFF.md).

**One card, two games.** Both are a single match between two sides over
eighteen holes, decided by holes won, and every slot answers the same question
in both. The only difference is how many names sit on a side — one, or two
joined by an ampersand. They are deliberately NOT two builders: two cards
differing by a conjunction drift apart within a release.

Two departures from every card before it, both from the umbrella packet:

* **Gross against par is on every state**, stake or no stake, quiet or loud.
  It is the number a golfer checks without meaning to and the only personal
  figure a neutral board can afford.
* **A no-stake round removes the footer, not the score.** Casual match play is
  often played for nothing, and gross and thru rattling around a row built to
  end in money looks like a bug for eighteen holes. The row goes; the two
  figures move up beside the hole.

**This card never pushes.** The push test is "could the reader have known this
from the hole they are standing on", and in a two-side match inside one group
the answer is always yes — both sides are within earshot of every putt. Not a
hole won, not dormie, not the close-out. That is a deliberate zero, not an
oversight, and it is why there is no `*_push` function in this module.
"""

KIND = 'match'

# The two slugs that draw this card. `match_18` is a 1-v-1 Overall-only Nassau
# riding the NassauGame model; `fourball` is its own engine. They share every
# slot, so they share the layout — the registry maps both here and the state
# declares `kind = 'match'` rather than either slug.
SLUGS = ('match_18', 'fourball')

_HOLES = 18


def _ordinal(n) -> str:
    """`15` -> `15TH`, for `ON THE 15TH`."""
    n = int(n or 0)
    if 10 <= n % 100 <= 20:
        suffix = 'TH'
    else:
        suffix = {1: 'ST', 2: 'ND', 3: 'RD'}.get(n % 10, 'TH')
    return f'{n}{suffix}'


def _cash(v) -> str:
    """`+$20` / `−$20`. A real minus sign, which is what the design draws."""
    v = float(v or 0)
    body = f'{abs(v):.2f}'.rstrip('0').rstrip('.')
    return ('−$' if v < 0 else '+$') + body


def _stake(v) -> str:
    """`$20 match` — the stake, which never goes stale."""
    v = float(v or 0)
    body = f'{v:.2f}'.rstrip('0').rstrip('.')
    return f'${body} match'


def _to_par(v) -> str:
    """`+2` / `E` / `−1`, the way a scoreboard writes it."""
    if v is None:
        return ''
    if v == 0:
        return 'E'
    return f'+{v}' if v > 0 else f'−{abs(v)}'


def _margin_text(margin) -> str:
    """`2 UP`, or `ALL SQ` — white at 90%, never mint. Mint is the app's
    colour and cannot name a side."""
    return f'{abs(margin)} UP' if margin else 'ALL SQ'


def _result_text(margin, remaining) -> str:
    """`4 & 3`, the golf notation: holes up by holes remaining.

    A match decided on the 18th is `1 UP`, not `1 & 0` — there were no holes
    left to be up by, and `& 0` is not something anyone says.
    """
    margin = abs(int(margin or 0))
    remaining = int(remaining or 0)
    return f'{margin} & {remaining}' if remaining else f'{margin} UP'


# ---------------------------------------------------------------------------
# The two engines, normalised
# ---------------------------------------------------------------------------
#
# Each returns the same small vocabulary so the composition below never asks
# which game it is drawing. Anything the composition has to branch on is a
# genuine difference between the games; everything else is normalised here.

def _normalise_nassau(foursome, player_id):
    """A Singles Match: an Overall-only Nassau on the NassauGame model."""
    from services.nassau import nassau_summary
    from services.live_activity_registry import gross_to_par

    summary = nassau_summary(foursome, game_type='match_18')
    if not summary:
        return None

    overall = summary.get('overall') or {}
    teams   = summary.get('teams') or {}

    def names(key):
        return ' & '.join((p.get('name') or '') for p in (teams.get(key) or []))

    margin = overall.get('margin') or 0
    # `decided_remaining` is set on the hole the match became unlosable, so its
    # presence IS the close-out. Reading it rather than re-deriving keeps one
    # implementation of "when is a match over".
    remaining = overall.get('decided_remaining')
    closed    = remaining is not None

    # Payouts are from team1's point of view; the reader may be on team2.
    payout = (summary.get('payouts') or {}).get('overall') or 0
    sign   = 1
    for p in (teams.get('team2') or []):
        if p.get('player_id') == player_id:
            sign = -1

    return {
        'game'      : 'SINGLES MATCH',
        'side1'     : names('team1'),
        'side2'     : names('team2'),
        'margin'    : margin,
        'leader'    : 'team1' if margin > 0 else ('team2' if margin < 0 else None),
        'played'    : overall.get('holes_played') or 0,
        'closed'    : closed,
        'decided'   : overall.get('decided_margin') or margin,
        'remaining' : remaining,
        'on_hole'   : (_HOLES - remaining) if closed else None,
        'halved'    : (overall.get('result') == 'halved'),
        'stake'     : summary.get('bet_unit') or 0,
        'payout'    : payout * sign,
        'to_par'    : gross_to_par(summary, player_id),
    }


def _normalise_fourball(foursome, player_id):
    """A Fourball: two pairings, one ball each, its own engine."""
    from services.fourball import fourball_summary

    summary = fourball_summary(foursome)
    if not summary:
        return None

    overall = summary.get('overall') or {}
    leader  = overall.get('leader')
    margin  = overall.get('holes_up') or 0
    if leader == 'team2':
        margin = -margin

    finished = summary.get('finished_on_hole')
    closed   = finished is not None

    money = (summary.get('money') or {})
    mine  = next((e.get('amount') for e in (money.get('by_player') or [])
                  if e.get('player_id') == player_id), None)

    return {
        'game'      : 'FOURBALL',
        'side1'     : ' & '.join((summary.get('team1') or {}).get('players') or []),
        'side2'     : ' & '.join((summary.get('team2') or {}).get('players') or []),
        'margin'    : margin,
        'leader'    : leader,
        'played'    : len(summary.get('holes') or []),
        'closed'    : closed,
        'decided'   : abs(margin),
        'remaining' : summary.get('holes_to_play'),
        'on_hole'   : finished,
        'halved'    : summary.get('result') == 'halved',
        'stake'     : money.get('bet_amount') or 0,
        'payout'    : mine,
        'to_par'    : _fourball_to_par(summary, player_id),
        'result_label': summary.get('result_label'),
    }


def _fourball_to_par(summary, player_id):
    """The reader's OWN gross against par — never the team's better ball.

    A team figure on a neutral board is a number nobody can check against their
    own card, which is the whole reason gross is allowed on a neutral board.

    Fourball keeps its per-hole scores under `scorecard`; the shared helper
    reads `holes`, so the list is handed over rather than the summary.
    """
    from services.live_activity_registry import gross_to_par
    return gross_to_par({'holes': summary.get('scorecard') or []}, player_id)


# ---------------------------------------------------------------------------
# The card
# ---------------------------------------------------------------------------

def match_activity_state(foursome, *, slug, player_id=None, thru=None) -> dict:
    """The five slots for this foursome's match, right now."""
    if slug == 'fourball':
        m = _normalise_fourball(foursome, player_id)
    else:
        m = _normalise_nassau(foursome, player_id)
    if not m:
        return {}

    played = m['played'] if thru is None else thru
    hole   = min(played + 1, _HOLES)

    # ── Sides. Assigned once and immutable for the round, which is what lets
    #    the number wear a side's colour for eighteen holes.
    leader = m['leader']
    sides = [
        {'names': m['side1'] or '—', 'colour': 'blue',
         'leading': leader == 'team1'},
        {'names': m['side2'] or '—', 'colour': 'orange',
         'leading': leader == 'team2'},
    ]

    # ── The big number, and the state word beneath it.
    if m['closed']:
        # The result, in the winner's colour. The match line never changes
        # again — but the header keeps advancing, because the group is still
        # playing golf and the reader's gross is still moving.
        number = {'text': m.get('result_label') or _result_text(m['decided'],
                                                                m['remaining']),
                  'colour': 'blue' if leader == 'team1' else 'orange'}
        state  = {'word': 'CLOSED',
                  'to_play': (f'ON THE {_ordinal(m["on_hole"])}'
                              if m['on_hole'] else '')}
    elif m['halved']:
        number = {'text': 'ALL SQ', 'colour': 'neutral'}
        state  = {'word': 'HALVED', 'to_play': ''}
    else:
        margin = m['margin']
        left   = max(_HOLES - played, 0)
        number = {'text': _margin_text(margin),
                  'colour': ('blue' if margin > 0 else
                             'orange' if margin < 0 else 'neutral')}
        # DORMIE when the lead equals the holes left — the one fact that
        # changes how the next tee shot gets played.
        if left and abs(margin) == left:
            state = {'word': 'DORMIE', 'to_play': f'{left} TO PLAY'}
        else:
            state = {'word': '—', 'to_play': f'{left} TO PLAY' if left else ''}

    # ── Header and footer, which trade places when there is no stake.
    par_txt  = _to_par(m['to_par'])
    thru_txt = f'THRU {played}' if played else ''
    staked   = bool(m['stake'])

    if staked:
        header = {'game': m['game'], 'segment': f'HOLE {hole}'}
        bits   = [b for b in (_to_par(m['to_par']),
                              f'Thru {played}' if played else '',
                              _stake(m['stake'])) if b]
        footer = {
            'context': ' · '.join(bits),
            # Settled money only. A single match settles exactly once, so this
            # is empty from the 1st to the 17th and holds one figure at the
            # end. `$0` would read as a match played for nothing.
            'money'  : (_cash(m['payout'])
                        if m['closed'] and m['payout'] else ''),
        }
    else:
        # No stake: the row goes, the score moves up beside the hole. A footer
        # whose right edge is permanently blank looks like a failed fetch.
        extra  = ' '.join(b for b in (par_txt, thru_txt) if b)
        header = {'game': m['game'],
                  'segment': f'HOLE {hole}' + (f' · {extra}' if extra else '')}
        footer = {'context': '', 'money': ''}

    return {
        'kind'  : KIND,
        'header': header,
        'number': number,
        'sides' : sides,
        'state' : state,
        # The 18-hole run strip lives only in expanded, where no footer
        # competes for the row. Nothing on the lock card uses pips.
        'pips'  : [],
        'footer': footer,
        'final' : None,
    }


def match_final_state(foursome, *, slug, player_id=None) -> dict:
    """Round sign — the one moment the board stops being neutral.

    Nobody needs a match summary on a lock screen at that point; they need to
    know who has the cash.
    """
    if slug == 'fourball':
        m = _normalise_fourball(foursome, player_id)
    else:
        m = _normalise_nassau(foursome, player_id)
    if not m:
        return {}

    payout = m['payout'] or 0
    won    = payout > 0

    if m['closed']:
        detail = f'{"Won" if won else "Lost"} ' + (
            m.get('result_label') or _result_text(m['decided'], m['remaining']))
    elif m['halved']:
        detail = 'Halved'
    else:
        detail = _margin_text(m['margin'])

    other = (m['side2'] if m['leader'] == 'team1' else m['side1']) or ''
    if m['leader'] is None or not payout:
        collect = ''
    elif won:
        collect = f'Collect from {other.split(" & ")[0]}'
    else:
        winner = (m['side1'] if m['leader'] == 'team1' else m['side2']) or ''
        collect = f'Pay {winner.split(" & ")[0]}'

    state = match_activity_state(foursome, slug=slug, player_id=player_id)
    if not state:
        return {}
    state['final'] = {
        # A halved or unstaked match pays nothing, and an empty amount is the
        # honest answer — never `$0`.
        'amount' : _cash(payout) if payout else '',
        'detail' : detail,
        'collect': collect,
    }
    return state
