"""
services/setup_edit.py
----------------------
Editing a tee or a forced handicap after the round has started, and undoing it.

Until now `FoursomeTeesView` refused the moment any real golfer posted a gross
score. Inside the 3-hole edit ceiling (`services/edit_window`) it no longer
does — and the reason that refusal existed in the first place is what this
module has to handle.

**Strokes are STORED, not computed.** `HoleScore.handicap_strokes` is
denormalised off the membership and `net_score` is stored for query
performance. So accepting a tee change is not a recompute, it is a **rewrite of
every scored row** for that golfer, after which every game's summary has to be
rebuilt on top of the new numbers. Get it wrong and you do not display a wrong
total — you corrupt completed holes.

Two consequences shape everything here:

1. **The rewrite has to be complete.** A round where hole 1 used one index and
   hole 3 used another is not a real result, so the edit is retroactive to the
   first hole or it does not happen. There is no "going forward only".
2. **The prior values have to be KEPT.** Once `handicap_strokes` has been
   overwritten there is nothing left to derive the old one from — so undo means
   storing the rows, not the setting. Under the ceiling that is at most three
   holes per golfer, which is what makes it affordable.

`net_score` and `stableford_points` are NOT written here. `HoleScore.save()`
derives both from `handicap_strokes`, and duplicating that arithmetic is how
the two come to disagree — so this sets the strokes and saves the row.
"""
from scoring.models import HoleScore

# The membership fields a setup edit can move. Kept as a tuple because snapshot
# and restore must agree on the list, and two hand-written lists is how a field
# comes to be captured but never put back.
MEMBERSHIP_FIELDS = ('tee_id', 'course_handicap', 'playing_handicap',
                     'playing_handicap_override')

# The HoleScore fields the rescore overwrites. `net_score` and
# `stableford_points` are derived on save, but they are captured anyway: a
# restore that set the strokes and let the model re-derive would be correct
# today and silently wrong the day the derivation changes.
HOLE_FIELDS = ('handicap_strokes', 'net_score', 'stableford_points')


def _real_memberships(foursome):
    return list(foursome.memberships.select_related('player', 'tee')
                .filter(player__is_phantom=False))


def snapshot(foursome, player_ids=None) -> dict:
    """Everything an edit is about to overwrite, in a JSON-safe shape.

    Call BEFORE applying the change. `player_ids` scopes it to the golfers
    being edited; None captures the whole foursome, which is what a tee change
    needs — a new tee can shift the group's lowest par and so re-derive every
    real member's par-adjusted playing handicap, not just the one that moved.
    """
    rows = _real_memberships(foursome)
    if player_ids is not None:
        wanted = set(player_ids)
        rows = [m for m in rows if m.player_id in wanted]
    pids = [m.player_id for m in rows]

    return {
        'memberships': [
            {'player_id': m.player_id,
             **{f: getattr(m, f) for f in MEMBERSHIP_FIELDS}}
            for m in rows
        ],
        'hole_scores': [
            {'player_id': hs.player_id, 'hole_number': hs.hole_number,
             **{f: getattr(hs, f) for f in HOLE_FIELDS}}
            for hs in HoleScore.objects.filter(
                foursome=foursome, player_id__in=pids,
                gross_score__isnull=False).order_by('player_id', 'hole_number')
        ],
    }


def rescore(foursome, player_ids=None) -> int:
    """Rewrite every scored hole's handicap strokes from the CURRENT memberships.

    Returns the number of rows touched — which the caller reports, because
    "4 holes rescored" is the sentence a golfer needs before the money moves.

    Retroactive to hole 1 by design: applying a new tee going forward only
    would leave the round scored under two different allocations.
    """
    by_pid = {m.player_id: m for m in _real_memberships(foursome)
              if m.tee_id is not None}
    if player_ids is not None:
        wanted = set(player_ids)
        by_pid = {p: m for p, m in by_pid.items() if p in wanted}
    if not by_pid:
        return 0

    touched = 0
    for hs in HoleScore.objects.filter(foursome=foursome,
                                       player_id__in=list(by_pid),
                                       gross_score__isnull=False):
        m  = by_pid[hs.player_id]
        si = m.tee.hole(hs.hole_number).get('stroke_index', 18)
        # hole_number so a partial round scales and re-ranks the handicap —
        # the same call the score-submit path makes, so an edited round and a
        # freshly entered one cannot allocate differently.
        strokes = m.handicap_strokes_on_hole(si, hs.hole_number)
        if strokes == hs.handicap_strokes:
            continue
        hs.handicap_strokes = strokes
        hs.save()                      # net_score + stableford follow
        touched += 1
    return touched


def restore(foursome, payload: dict) -> int:
    """Put back exactly what `snapshot` captured. Returns rows restored.

    Writes the stored values rather than re-deriving them. Re-deriving is what
    got us here: the numbers being restored were computed under settings that
    no longer exist anywhere.
    """
    if not payload:
        return 0
    n = 0

    by_pid = {m.player_id: m for m in _real_memberships(foursome)}
    for row in payload.get('memberships') or []:
        m = by_pid.get(row.get('player_id'))
        if m is None:
            continue
        for f in MEMBERSHIP_FIELDS:
            if f in row:
                setattr(m, f, row[f])
        m.save(update_fields=list(MEMBERSHIP_FIELDS))
        n += 1

    for row in payload.get('hole_scores') or []:
        hs = HoleScore.objects.filter(
            foursome=foursome, player_id=row.get('player_id'),
            hole_number=row.get('hole_number')).first()
        if hs is None:
            continue
        for f in HOLE_FIELDS:
            if f in row:
                setattr(hs, f, row[f])
        # update_fields, NOT save() — the model's save() would re-derive
        # net_score from handicap_strokes and quietly overwrite the restored
        # value. Here the stored numbers ARE the truth.
        HoleScore.objects.filter(pk=hs.pk).update(
            **{f: getattr(hs, f) for f in HOLE_FIELDS})
        n += 1
    return n


def describe(before: dict, foursome) -> str:
    """`Kevin: Blue → White · Sam: hcp 12 → 9` — what an undo would put back.

    Short enough for a button, specific enough that somebody who has walked two
    holes since can tell whether it is the edit they mean.
    """
    prior = {r['player_id']: r for r in (before.get('memberships') or [])}
    names = {m.player_id: (m.player.short_name or m.player.name)
             for m in _real_memberships(foursome)}
    tees  = {}
    bits  = []
    for m in _real_memberships(foursome):
        was = prior.get(m.player_id)
        if not was:
            continue
        who = names.get(m.player_id, 'Golfer')
        if was.get('tee_id') != m.tee_id:
            old = tees.get(was.get('tee_id'))
            if old is None and was.get('tee_id'):
                from core.models import Tee
                t = Tee.objects.filter(pk=was['tee_id']).first()
                old = tees[was['tee_id']] = (t.tee_name if t else '?')
            bits.append(f'{who}: {old or "—"} → '
                        f'{m.tee.tee_name if m.tee_id else "—"}')
        elif was.get('playing_handicap') != m.playing_handicap:
            bits.append(f'{who}: hcp {was.get("playing_handicap")} → '
                        f'{m.playing_handicap}')
    return ' · '.join(bits)[:200]


def store_undo(foursome, before: dict, user=None) -> None:
    """Keep one step back, replacing whatever was there.

    A second edit makes the first permanent — which is why the confirmation
    sheet has to say so while a prior value already exists, rather than letting
    somebody edit twice and discover the first is unreachable.
    """
    from tournament.models import FoursomeSetupUndo
    FoursomeSetupUndo.objects.update_or_create(
        foursome=foursome,
        defaults={'payload': before,
                  'note': describe(before, foursome),
                  'created_by': user if getattr(user, 'pk', None) else None},
    )
