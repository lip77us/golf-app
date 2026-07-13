"""
services/messaging_events.py — Slice 3: server-generated event messages.

Detects scoring events and posts them to the round's message thread (idempotent
via ``event_key``) plus an optional push (idempotent via SentNotification, gated
by each user's category toggle). The feed ALWAYS populates; push respects the
user's per-category preference.

Design rules (see docs/messaging-slice3-plan.md):
* No gate — every round emits events (a lone scorer still sees them; growth hook).
* Best-effort — a failure here must NEVER break score submission / completion.
  Every public ``emit_*`` is fully wrapped; ``_emit`` swallows + logs per event.
* Player names, never team labels, in user-facing text.

Increment 1 (this file): round started/complete, gross scorecard recap, birdies,
withdrawal. Increment 2 will add skins, match results, and money-lead / front-9.
"""
import logging

from services import messaging

logger = logging.getLogger(__name__)


def _emit(round_obj, *, event_key, body, data, push_category=None,
          push_title=None, exclude_user_ids=()):
    """Post one event to the feed (idempotent) and optionally push it. Never
    raises — returns the Message, or None on any failure."""
    try:
        thread = messaging.get_or_create_thread(round_obj)
        msg = messaging.post_event(
            thread, event_key=event_key, body=body, data=data)
        if push_category:
            from services.push import notify_round_event
            notify_round_event(
                round_obj, category=push_category, dedup_key=event_key,
                title=push_title or 'Halved', body=body, data=data,
                exclude_user_ids=exclude_user_ids)
        return msg
    except Exception:  # pragma: no cover - defensive
        logger.exception('messaging_events: emit failed (%s)', event_key)
        return None


# --------------------------------------------------------------------------
# Round lifecycle (feed cards; push for these is handled by push.maybe_notify_*)
# --------------------------------------------------------------------------

def emit_round_started(round_obj):
    try:
        from services.catalog import normalize_course_name
        _emit(round_obj,
              event_key=f'round_start:{round_obj.id}',
              body=f'Round under way at {normalize_course_name(round_obj.course.name)}.',
              data={'type': 'round_started'})
    except Exception:  # pragma: no cover
        logger.exception('emit_round_started failed (round %s)', round_obj.id)


def emit_round_complete(round_obj):
    try:
        _emit(round_obj,
              event_key=f'round_complete:{round_obj.id}',
              body='Round complete — see final results.',
              data={'type': 'round_complete'})
        _emit_gross_recap(round_obj)
    except Exception:  # pragma: no cover
        logger.exception('emit_round_complete failed (round %s)', round_obj.id)


def _emit_gross_recap(round_obj):
    """Feed-only card: every competitor's GROSS front-back-18 (e.g. 41-40-81),
    lowest total first. Withdrawn players show ``WD`` (no numbers). Skipped for
    Triple Cup (team match play — a per-player stroke total isn't the point)."""
    if 'triple_cup' in (round_obj.active_games or []):
        return
    from scoring.models import HoleScore

    score_map = {}  # (foursome_id, player_id) -> {hole: gross}
    for hs in (HoleScore.objects
               .filter(foursome__round=round_obj, player__is_phantom=False)
               .values('foursome_id', 'player_id', 'hole_number', 'gross_score')):
        if hs['gross_score'] is None:
            continue
        key = (hs['foursome_id'], hs['player_id'])
        score_map.setdefault(key, {})[hs['hole_number']] = hs['gross_score']

    players = []
    for fs in round_obj.foursomes.all():
        for m in (fs.memberships
                  .filter(player__is_phantom=False)
                  .select_related('player')):
            p = m.player
            if m.withdrew_after_hole is not None:
                players.append({'player_id': p.id, 'name': p.name,
                                'withdrew': True,
                                'front': None, 'back': None, 'total': None})
                continue
            holes = score_map.get((fs.id, p.id), {})
            if not holes:
                continue  # no scores at all — skip rather than show 0-0-0
            front = sum(g for h, g in holes.items() if 1 <= h <= 9)
            back = sum(g for h, g in holes.items() if 10 <= h <= 18)
            players.append({'player_id': p.id, 'name': p.name,
                            'withdrew': False,
                            'front': front, 'back': back, 'total': front + back})

    if not players:
        return

    # Lowest gross first; withdrawn players last.
    players.sort(key=lambda x: (x['withdrew'],
                                x['total'] if x['total'] is not None else 10**9))

    parts = [
        f"{x['name']} WD" if x['withdrew']
        else f"{x['name']} {x['front']}-{x['back']}-{x['total']}"
        for x in players
    ]
    _emit(round_obj,
          event_key=f'score_report:{round_obj.id}',
          body='Scores — ' + ', '.join(parts),
          data={'type': 'score_report', 'players': players})


# --------------------------------------------------------------------------
# Withdrawal
# --------------------------------------------------------------------------

def emit_withdrawal(foursome, player, after_hole, killed_next=False):
    try:
        round_obj = foursome.round
        where = (f'after hole {after_hole}' if after_hole
                 else 'before the round')
        _emit(round_obj,
              event_key=f'wd:{round_obj.id}:{player.id}:{after_hole}',
              body=f'{player.name} withdrew {where}.',
              data={'type': 'withdrawal', 'player_id': player.id,
                    'player_name': player.name,
                    'after_hole': after_hole, 'killed_next': killed_next},
              push_category='withdrawal', push_title='Withdrawal')
    except Exception:  # pragma: no cover
        logger.exception('emit_withdrawal failed (foursome %s)', foursome.id)


# --------------------------------------------------------------------------
# Per-hole score events (Increment 1: birdies; Increment 2 adds skins/matches)
# --------------------------------------------------------------------------

def emit_score_events(foursome, hole_number, submitted):
    """Called from ScoreSubmitView after recalc. ``submitted`` is the list of
    ``{player_id, gross_score}`` just posted for ``hole_number``. Each detector
    is independently guarded so one failing can't suppress the others."""
    _guard(_emit_birdies, foursome, hole_number, submitted)
    _guard(_emit_front9_recap, foursome, hole_number)
    _guard(_emit_skins, foursome)
    _guard(_emit_multi_skins, foursome)
    _guard(_emit_match_results, foursome)


def _guard(fn, *args):
    try:
        fn(*args)
    except Exception:  # pragma: no cover
        logger.exception('emit_score_events: %s failed', fn.__name__)


def _active_games(foursome):
    return (set(foursome.active_games or [])
            | set(foursome.round.active_games or []))


def _side_names(players):
    """'A & B' (full names) from a list of player dicts ({'name': …}) or names.
    Players don't know team numbers, so every team-based event names the people."""
    names = [(p['name'] if isinstance(p, dict) else p) for p in (players or [])]
    return ' & '.join(n for n in names if n)


_UNDER_PAR = {1: ('birdie', 'birdie'), 2: ('eagle', 'an eagle'),
              3: ('albatross', 'an albatross')}


def _emit_birdies(foursome, hole_number, submitted):
    """Gross birdie/eagle/albatross/hole-in-one. One card per player-hole
    (`birdie:{round}:{hole}:{player}`) — a later score edit does not re-announce."""
    round_obj = foursome.round
    membership_map = {
        m.player_id: m
        for m in foursome.memberships.select_related('player', 'tee').all()
    }
    for s in submitted:
        pid = s.get('player_id')
        gross = s.get('gross_score')
        m = membership_map.get(pid)
        if m is None or m.player.is_phantom or not gross:
            continue
        try:
            par = m.tee.hole(hole_number).get('par')
        except Exception:
            par = None
        if not par:
            continue

        if gross == 1:
            etype, phrase = 'hole_in_one', 'a hole-in-one'
        else:
            diff = par - gross
            if diff >= 3:
                etype, phrase = _UNDER_PAR[3]
            elif diff in _UNDER_PAR:
                etype, phrase = _UNDER_PAR[diff]
            else:
                continue

        name = m.player.name
        body = (f'{name} aced hole {hole_number}!' if etype == 'hole_in_one'
                else f'{name} made {phrase} on hole {hole_number}!')
        _emit(round_obj,
              event_key=f'birdie:{round_obj.id}:{hole_number}:{pid}',
              body=body,
              data={'type': etype, 'hole': hole_number, 'player_id': pid,
                    'player_name': name, 'gross': gross, 'par': par},
              push_category='birdie', push_title='Nice shot!')


def _emit_front9_recap(foursome, hole_number):
    """Feed card at the turn: each player's GROSS front-nine total, lowest first
    (e.g. "Front 9 done — Paul 41, Jenn 44"). Posts once per foursome, only once
    every non-withdrawn real player has all nine front scores in. Fires for ANY
    game (it's just a scorecard recap), feed-only like the round-complete recap.
    Only bothers to check while scoring the front nine."""
    if hole_number > 9:
        return
    from scoring.models import HoleScore
    round_obj = foursome.round

    front = {}  # player_id -> {hole: gross}
    for hs in (HoleScore.objects
               .filter(foursome=foursome, player__is_phantom=False,
                       hole_number__lte=9)
               .values('player_id', 'hole_number', 'gross_score')):
        if hs['gross_score'] is None:
            continue
        front.setdefault(hs['player_id'], {})[hs['hole_number']] = hs['gross_score']

    players = []
    for m in (foursome.memberships
              .filter(player__is_phantom=False)
              .select_related('player')):
        p = m.player
        holes = front.get(p.id, {})
        # A player who withdrew on the front nine only needs the holes they
        # actually played; they show as WD (no total) rather than blocking.
        wd_front = (m.withdrew_after_hole is not None
                    and m.withdrew_after_hole < 9)
        last_needed = min(m.withdrew_after_hole, 9) if wd_front else 9
        if any(h not in holes for h in range(1, last_needed + 1)):
            return  # someone still owes a front-nine score — wait
        if wd_front:
            players.append({'player_id': p.id, 'name': p.name,
                            'withdrew': True, 'front': None})
        else:
            players.append({'player_id': p.id, 'name': p.name,
                            'withdrew': False,
                            'front': sum(holes[h] for h in range(1, 10))})
    if not players:
        return

    players.sort(key=lambda x: (x['withdrew'],
                                x['front'] if x['front'] is not None else 10**9))
    parts = [f"{x['name']} WD" if x['withdrew'] else f"{x['name']} {x['front']}"
             for x in players]
    _emit(round_obj,
          event_key=f'front9_recap:{round_obj.id}:{foursome.id}',
          body='Front 9 done — ' + ', '.join(parts),
          data={'type': 'front9_recap', 'players': players})  # feed-only


def _emit_skins(foursome):
    """Skin won (push) / carryover (feed-only). Reads the post-recalc summary;
    a hole is decided when it has a winner or carries. Keyed per foursome+hole,
    so re-scanning on every submit only posts newly-decided holes."""
    if 'skins' not in _active_games(foursome):
        return
    from services.skins import skins_summary
    summary = skins_summary(foursome)
    if not summary:
        return
    round_obj = foursome.round
    name_by_id = {p['player_id']: p['name'] for p in summary.get('players', [])}
    for h in summary.get('holes', []):
        hole = h.get('hole')
        wid = h.get('winner_id')
        if wid:
            name = name_by_id.get(wid) or h.get('winner_short') or 'Someone'
            val = h.get('skins_value') or 1
            body = (f'{name} won {val} skins on hole {hole}!' if val > 1
                    else f'{name} won the skin on hole {hole}!')
            _emit(round_obj,
                  event_key=f'skin:{round_obj.id}:{foursome.id}:{hole}',
                  body=body,
                  data={'type': 'skin', 'hole': hole, 'player_id': wid,
                        'player_name': name, 'skins_value': val},
                  push_category='skins', push_title='Skin won')
        elif h.get('is_carry'):
            _emit(round_obj,
                  event_key=f'skincarry:{round_obj.id}:{foursome.id}:{hole}',
                  body=f'Hole {hole} halved — the skin carries.',
                  data={'type': 'carryover', 'hole': hole})  # feed-only


def _emit_multi_skins(foursome):
    """Round-level multi-group skins: announce a hole's skin when it's won
    across the whole field. Keyed per round+hole (group-agnostic)."""
    round_obj = foursome.round
    if 'multi_skins' not in (round_obj.active_games or []):
        return
    from services.multi_skins import multi_skins_summary
    s = multi_skins_summary(round_obj)
    if not s:
        return
    name_by_id = {p['player_id']: p['name'] for p in s.get('players', [])}
    for h in s.get('holes', []):
        wid = h.get('winner_id')
        if not wid:
            continue
        hole = h.get('hole')
        name = name_by_id.get(wid) or h.get('winner_short') or 'Someone'
        _emit(round_obj,
              event_key=f'multiskin:{round_obj.id}:{hole}',
              body=f'{name} won the skin on hole {hole}!',
              data={'type': 'skin', 'hole': hole, 'player_id': wid,
                    'player_name': name},
              push_category='skins', push_title='Skin won')


# --------------------------------------------------------------------------
# Match results — Nassau nines & Sixes segments (Match Play / Triple Cup next)
# --------------------------------------------------------------------------

def _slug(s):
    return '-'.join(''.join(c if c.isalnum() else ' ' for c in (s or '')).split()).lower()


def _emit_match_results(foursome):
    games = _active_games(foursome)
    # A foursome can hold more than one Nassau-family match (team Nassau +
    # Singles Match + Nassau Nine); announce each independently.
    from services.nassau import nassau_game_types_for
    for _gt in nassau_game_types_for(foursome):
        _emit_nassau_results(foursome, game_type=_gt)
        _emit_nassau_bottom_results(foursome, game_type=_gt)
        _emit_nassau_presses(foursome, game_type=_gt)
    if 'sixes' in games:
        _emit_sixes_results(foursome)
    if 'match_play' in games:
        _emit_match_play_results(foursome)
    if 'triple_cup' in games:
        _emit_triple_cup_results(foursome)


_NINE = {
    'front9':  ('the front nine', 9),
    'back9':   ('the back nine', 9),
    'overall': ('the overall match', 18),
}


def _emit_nassau_results(foursome, game_type='nassau'):
    """Announce each Nassau nine (front / back / overall) once it's complete."""
    from services.nassau import nassau_summary
    s = nassau_summary(foursome, game_type)
    if not s:
        return
    round_obj = foursome.round
    team1 = s.get('teams', {}).get('team1', [])
    team2 = s.get('teams', {}).get('team2', [])
    for unit, (label, holes) in _NINE.items():
        seg = s.get(unit) or {}
        # Announce the MOMENT the nine is won — either mathematically decided
        # before the last hole (decided_margin set → "3&2" style) or played out
        # (result set → "2 up" / halved). Skip while still live.
        dm       = seg.get('decided_margin')
        complete = (seg.get('holes_played') or 0) >= holes
        if dm is None and not complete:
            continue
        if dm is not None:
            margin = abs(dm)
            rem    = seg.get('decided_remaining') or 0
            result = 'team1' if dm > 0 else 'team2'
            names  = team1 if result == 'team1' else team2
            tail   = f'{margin}&{rem}' if rem > 0 else f'{margin} up'
            body   = f'{_side_names(names)} won {label}, {tail}.'
        else:
            result = seg.get('result')
            margin = abs(seg.get('margin') or 0)
            if result == 'team1' and margin:
                body = f'{_side_names(team1)} won {label}, {margin} up.'
            elif result == 'team2' and margin:
                body = f'{_side_names(team2)} won {label}, {margin} up.'
            else:
                body = f'{label[0].upper()}{label[1:]} was halved.'
        _emit(round_obj,
              event_key=f'nassau:{game_type}:{unit}:{round_obj.id}:{foursome.id}',
              body=body,
              data={'type': 'match_result', 'game': game_type, 'unit': unit,
                    'result': result or 'halved', 'margin': margin},
              push_category='match_result', push_title='Match result')


_BOTTOM_NINE = {
    'bottom_front9':  ('the bottom front nine', 9),
    'bottom_back9':   ('the bottom back nine', 9),
    'bottom_overall': ('the bottom overall match', 18),
}


def _emit_nassau_bottom_results(foursome, game_type='nassau'):
    """Announce each Claremont BOTTOM nine (front / back / overall) once
    complete. The bottom bet is worth 2 points/hole, so its margin is in POINTS
    ("4 pts"). No-op unless the game is Claremont (bottom_* blocks are null)."""
    from services.nassau import nassau_summary
    s = nassau_summary(foursome, game_type)
    if not s or not s.get('bottom_front9'):   # null unless variant == 'claremont'
        return
    round_obj = foursome.round
    team1 = s.get('teams', {}).get('team1', [])
    team2 = s.get('teams', {}).get('team2', [])
    for unit, (label, holes) in _BOTTOM_NINE.items():
        seg = s.get(unit) or {}
        if (seg.get('holes_played') or 0) < holes:
            continue  # nine not finished yet
        result = seg.get('result')
        margin = abs(seg.get('margin') or 0)
        if result == 'team1' and margin:
            body = f'{_side_names(team1)} won {label}, {margin} pts.'
        elif result == 'team2' and margin:
            body = f'{_side_names(team2)} won {label}, {margin} pts.'
        else:
            body = f'{label[0].upper()}{label[1:]} was halved.'
        _emit(round_obj,
              event_key=f'nassaubot:{game_type}:{unit}:{round_obj.id}:{foursome.id}',
              body=body,
              data={'type': 'match_result', 'game': f'{game_type}_bottom',
                    'unit': unit, 'result': result or 'halved', 'margin': margin},
              push_category='match_result', push_title='Match result')


def _press_labels(presses):
    """Map each press to its app-facing label ("F9 Press 1", "B9 Press 2"):
    numbered sequentially within its nine by start hole, matching the mobile
    presses strip. Returns {(nine, start_hole): 'F9 Press N'}."""
    labels, counters = {}, {}
    for p in sorted(presses, key=lambda x: (x.get('nine') or '',
                                            x.get('start_hole') or 0)):
        nine = p.get('nine')
        counters[nine] = counters.get(nine, 0) + 1
        prefix = 'F9' if nine == 'front' else 'B9'
        labels[(nine, p.get('start_hole'))] = f'{prefix} Press {counters[nine]}'
    return labels


def _emit_nassau_presses(foursome, game_type='nassau'):
    """Announce each Nassau press once it's decided (won or halved) — both the
    top series and the Claremont BOTTOM series (labelled "Bot …"). Keyed per
    press so re-scanning on every submit posts each once."""
    from services.nassau import nassau_summary
    s = nassau_summary(foursome, game_type)
    if not s:
        return
    round_obj = foursome.round
    team1 = s.get('teams', {}).get('team1', [])
    team2 = s.get('teams', {}).get('team2', [])
    _emit_press_group(round_obj, foursome, s.get('presses', []),
                      team1, team2, is_bottom=False, game_type=game_type)
    _emit_press_group(round_obj, foursome, s.get('bottom_presses', []),
                      team1, team2, is_bottom=True, game_type=game_type)


def _emit_press_group(round_obj, foursome, presses, team1, team2, *, is_bottom,
                      game_type='nassau'):
    """Emit one press series. Top margins are in holes ("2&1" / "2 up"); the
    Claremont bottom series is in POINTS ("4 pts") and its label + event key
    carry "Bot" so it's distinct from the top press at the same start hole."""
    if not presses:
        return
    labels = _press_labels(presses)
    prefix = 'Bot ' if is_bottom else ''
    kind   = 'nassaubotpress' if is_bottom else 'nassaupress'
    for p in presses:
        result = p.get('result')
        if not result:
            continue  # still open
        nine, start = p.get('nine'), p.get('start_hole')
        label = prefix + labels.get((nine, start), 'Press')
        m = abs(p.get('margin') or 0)
        if is_bottom:
            margin_txt = f'{m} pts' if m else ''
        else:
            rem = p.get('holes_remaining') or 0
            margin_txt = f'{m}&{rem}' if rem > 0 else (f'{m} up' if m else '')
        if result == 'team1':
            body = f'{_side_names(team1)} won {label}' + (f', {margin_txt}.' if margin_txt else '.')
        elif result == 'team2':
            body = f'{_side_names(team2)} won {label}' + (f', {margin_txt}.' if margin_txt else '.')
        else:
            body = f'{label} was halved.'
        _emit(round_obj,
              event_key=f'{kind}:{game_type}:{round_obj.id}:{foursome.id}:{nine}:{start}',
              body=body,
              data={'type': 'match_result', 'game': 'nassau_press',
                    'game_type': game_type,
                    'nine': nine, 'label': label, 'result': result,
                    'margin': m, 'bottom': is_bottom},
              push_category='match_result', push_title='Press result')


def emit_nassau_press_called(foursome, start_hole, game_type='nassau'):
    """Announce a manually-called press (from NassauPressView, after the press
    is added). Names the trailing side that pressed, and the press label."""
    try:
        from services.nassau import nassau_summary
        s = nassau_summary(foursome, game_type)
        if not s:
            return
        round_obj = foursome.round
        nine   = 'front' if start_hole <= 9 else 'back'
        label  = _press_labels(s.get('presses', [])).get((nine, start_hole), 'Press')
        # Presser = the side that's DOWN on this nine (only the trailing team
        # may press). front9/back9 margin: +ve = team1 up, -ve = team2 up.
        seg    = s.get(f'{nine}9') or {}
        margin = seg.get('margin') or 0
        team1  = s.get('teams', {}).get('team1', [])
        team2  = s.get('teams', {}).get('team2', [])
        who = _side_names(team2) if margin > 0 else (
              _side_names(team1) if margin < 0 else '')
        lead = f'{who} pressed' if who else 'New press'
        body = f'{lead} on hole {start_hole} — {label} is on.'
        _emit(round_obj,
              event_key=f'nassaupresscall:{game_type}:{round_obj.id}:{foursome.id}:{nine}:{start_hole}',
              body=body,
              data={'type': 'press_called', 'game': game_type,
                    'nine': nine, 'label': label, 'start_hole': start_hole},
              push_category='match_result', push_title='New press')
    except Exception:  # pragma: no cover - defensive
        logger.exception('emit_nassau_press_called failed (foursome %s)',
                         foursome.id)


def _emit_sixes_results(foursome):
    """Announce each Sixes segment once it's decided (skip voided segments)."""
    from services.sixes import sixes_summary
    s = sixes_summary(foursome)
    if not s:
        return
    round_obj = foursome.round
    for seg in s.get('segments', []):
        if seg.get('is_void') or seg.get('status') != 'complete':
            continue
        start, end = seg.get('start_hole'), seg.get('end_hole')
        where = f'holes {start}-{end}'
        winner = seg.get('winner')
        if winner == 'Team 1':
            body = f"{_side_names(seg['team1']['players'])} took {where}."
        elif winner == 'Team 2':
            body = f"{_side_names(seg['team2']['players'])} took {where}."
        else:  # Halved
            body = f'{where[0].upper()}{where[1:]} were halved.'
        _emit(round_obj,
              event_key=f'sixes:{round_obj.id}:{foursome.id}:{start}',
              body=body,
              data={'type': 'match_result', 'game': 'sixes',
                    'segment': where, 'winner': winner},
              push_category='match_result', push_title='Match result')


def _emit_match_play_results(foursome):
    """Bracket match results (4-player Match Play). 3-player groups play
    three-person match — its summary has no single 'winner' field, deferred."""
    from services.match_play import match_play_summary
    s = match_play_summary(foursome)
    if not s:
        return
    round_obj = foursome.round
    for m in s.get('matches', []):
        if m.get('status') != 'complete':
            continue
        result = m.get('result')
        label = m.get('label') or 'match'
        p1, p2 = m.get('player1'), m.get('player2')
        if result == 'halved':
            body = f'{p1} and {p2} halved ({label}).'
        elif result in ('player1', 'player2'):
            winner = m.get('winner_name') or (p1 if result == 'player1' else p2)
            loser = p2 if result == 'player1' else p1
            body = f'{winner} beat {loser} ({label}).'
        else:
            continue
        _emit(round_obj,
              event_key=f'matchplay:{round_obj.id}:{foursome.id}:{_slug(label)}',
              body=body,
              data={'type': 'match_result', 'game': 'match_play',
                    'match': label, 'result': result},
              push_category='match_result', push_title='Match result')


def _emit_triple_cup_results(foursome):
    """Triple Cup per-match results (Fourball / Foursomes / Singles)."""
    from services.triple_cup import triple_cup_summary
    s = triple_cup_summary(foursome)
    if not s:
        return
    round_obj = foursome.round
    for m in s.get('matches', []):
        if m.get('status') != 'complete':
            continue
        result = m.get('result')
        label = m.get('label') or 'match'
        margin = abs(m.get('holes_up_final') or 0)
        t1 = _side_names(m.get('team1', {}).get('players', []))
        t2 = _side_names(m.get('team2', {}).get('players', []))
        if result == 'team1':
            body = f'{t1} won the {label}' + (f', {margin} up.' if margin else '.')
        elif result == 'team2':
            body = f'{t2} won the {label}' + (f', {margin} up.' if margin else '.')
        elif result == 'halved':
            body = f'The {label} was halved.'
        else:
            continue
        _emit(round_obj,
              event_key=f'triplecup:{round_obj.id}:{foursome.id}:{_slug(label)}',
              body=body,
              data={'type': 'match_result', 'game': 'triple_cup',
                    'match': label, 'result': result, 'margin': margin},
              push_category='match_result', push_title='Match result')
