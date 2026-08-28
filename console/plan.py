"""
console/plan.py
---------------
The bridge between ``services/genius_import`` and the import screens.

Three jobs, in order:

1. **Serialize the parsed file** so a preview survives a round trip.  The TD
   types an index into a skipped row; the page re-posts; the plan is rebuilt
   from these rows plus the overrides.  No re-upload, no re-export.
2. **Rebuild the plan** from a stored run.
3. **Shape the plan for the template** — and this is where the storage
   conventions stop.  A plus handicap stored as ``-2.3`` leaves here as
   ``+2.3``, because that is what is printed on the sheet the TD is holding.
   Skip reasons leave as sentences.  No enum reaches a template raw.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from services import genius_import as gi


# ---------------------------------------------------------------------------
# Display formatting
# ---------------------------------------------------------------------------

def fmt_index(value) -> str:
    """A handicap index the way a golfer writes it.

    The parser stores a plus handicap below scratch as a negative — ``+2.3``
    becomes ``-2.3``.  That is a storage convention; on screen it would read as
    a bug, so it is undone here and nowhere else.
    """
    if value is None or value == '':
        return '—'
    d = value if isinstance(value, Decimal) else Decimal(str(value))
    if d < 0:
        return f'+{-d}'
    return f'{d}'


def is_plus(value) -> bool:
    """True for a plus handicap — the console tints those so the sign reads as
    deliberate rather than as a stray character."""
    if value is None or value == '':
        return False
    d = value if isinstance(value, Decimal) else Decimal(str(value))
    return d < 0


def fmt_phone(e164: str) -> str:
    """``+14155550182`` -> ``+1 415 555 0182``.  Falls back to the input for
    anything that isn't a plain 11-digit North American number."""
    if not e164:
        return '—'
    digits = ''.join(c for c in e164 if c.isdigit())
    if e164.startswith('+1') and len(digits) == 11:
        return f'+1 {digits[1:4]} {digits[4:7]} {digits[7:]}'
    return e164


def parse_typed_index(raw: str) -> Decimal | None:
    """Parse an index a TD typed into the preview.

    Deliberately stricter than the file parser: it accepts the plus-handicap
    form (``+2.3``) because that is how a golfer writes it, and rejects the
    no-handicap sentinels (``NH``, ``WD``).  Somebody typing ``NH`` into the box
    means "leave it skipped", not "create with no index".
    """
    raw = (raw or '').strip()
    if not raw:
        return None
    neg = raw.startswith('+')
    try:
        val = Decimal(raw.lstrip('+'))
    except InvalidOperation:
        return None
    val = -val if neg else val
    if not (gi.INDEX_MIN <= val <= gi.INDEX_MAX):
        return None
    return val


# ---------------------------------------------------------------------------
# Serialize / rebuild
# ---------------------------------------------------------------------------

_ROW_FIELDS = ('line', 'name', 'email', 'phone_raw', 'phone', 'ghin', 'sex',
               'error', 'error_code', 'index_raw')


def serialize_rows(parsed: list[gi.ParsedRow]) -> list[dict]:
    """ParsedRow[] -> JSON-safe dicts for ``ImportRun.parsed``."""
    out = []
    for r in parsed:
        d = {f: getattr(r, f) for f in _ROW_FIELDS}
        d['index'] = str(r.index) if r.index is not None else None
        out.append(d)
    return out


def deserialize_rows(data: list[dict]) -> list[gi.ParsedRow]:
    """The inverse.  Rebuilt rows carry no override — ``build_plan`` applies
    those, so a rebuild always starts from what the file actually said."""
    rows = []
    for d in data:
        rows.append(gi.ParsedRow(
            line=d['line'], name=d['name'], email=d['email'],
            phone_raw=d['phone_raw'], phone=d['phone'], ghin=d['ghin'],
            sex=d['sex'],
            index=Decimal(d['index']) if d.get('index') is not None else None,
            error=d.get('error'), error_code=d.get('error_code', ''),
            index_raw=d.get('index_raw', ''),
        ))
    return rows


def overrides_for(run) -> dict[int, Decimal]:
    """``ImportRun.overrides`` (JSON keys are strings) as build_plan wants it."""
    out: dict[int, Decimal] = {}
    for line, value in (run.overrides or {}).items():
        parsed = parse_typed_index(str(value))
        if parsed is not None:
            out[int(line)] = parsed
    return out


def build(run) -> gi.ImportPlan:
    """The plan for a stored run: parsed rows + whatever the TD has typed."""
    return gi.build_plan(run.account, deserialize_rows(run.parsed),
                         index_overrides=overrides_for(run))


# ---------------------------------------------------------------------------
# Shape for the template
# ---------------------------------------------------------------------------

# Which fields the importer writes, and how each behaves.  Index and GHIN
# overwrite; email and phone only fill a blank.  A TD who can't see that will
# assume the import clobbers — and never clobbering an already-linked phone
# number is the one thing this importer is careful about.
_FIELD_LABELS = {
    'handicap_index': 'idx',
    'ghin':           'GHIN',
    'email':          'email',
    'phone':          'phone',
}
_BACKFILL_ONLY = {'email', 'phone'}
# The order diffs are read in, most-consequential first.  Explicit because
# ImportRun.result is a jsonb column and jsonb does NOT preserve key order —
# without this the receipt lists the same change in a different order than the
# preview did, which reads like a different change.
_FIELD_ORDER = ('handicap_index', 'ghin', 'phone', 'email')


def _ordered(fields) -> list:
    return sorted(fields, key=lambda f: (_FIELD_ORDER.index(f)
                                         if f in _FIELD_ORDER else len(_FIELD_ORDER), f))


def _diff(field: str, before, after) -> dict:
    """One field-level change, ready to render as ``idx 8.4 → 7.9``."""
    if field == 'handicap_index':
        before_txt, after_txt = fmt_index(before), fmt_index(after)
    elif field == 'phone':
        before_txt, after_txt = fmt_phone(before or ''), fmt_phone(after)
    else:
        before_txt, after_txt = (before or ''), after
    return {
        'label':     _FIELD_LABELS.get(field, field),
        'before':    before_txt if before not in (None, '') else '',
        'after':     after_txt,
        # Backfills are the reassuring half of the diff, so they say so out loud.
        'was_blank': field in _BACKFILL_ONLY and not before,
    }


def _skip_detail(item: gi.SkipItem) -> str:
    """The trailing clause that turns a reason into something actionable."""
    code, detail, row = item.code, item.detail or {}, item.row
    if code == gi.SKIP_NO_INDEX:
        # Quote what the cell actually read.  An empty cell and a cell reading
        # "WD" are the same skip but not the same problem.
        raw = (row.index_raw or '').strip()
        return f'index cell read “{raw}”' if raw else ''
    if code in (gi.SKIP_DUP_PHONE, gi.SKIP_DUP_GHIN):
        return f'row {detail.get("won_line")} was imported'
    if code == gi.SKIP_NO_NAME:
        return 'fix the export'
    if code == gi.SKIP_INDEX_RANGE:
        return f'allowed −10 to {detail.get("max", "54")}'
    if code == gi.SKIP_ALREADY_MATCHED:
        return 'two rows point at the same golfer'
    return ''


def _skip_reason(item: gi.SkipItem) -> str:
    """The reason as a sentence.  The CLI's lowercase fragments read as log
    lines; these are the same six reasons written for a person."""
    code = item.code
    if code == gi.SKIP_NO_INDEX:
        return 'New golfer has no index'
    if code == gi.SKIP_DUP_PHONE:
        return 'Duplicate phone in file'
    if code == gi.SKIP_DUP_GHIN:
        return 'Duplicate GHIN in file'
    if code == gi.SKIP_NO_NAME:
        return 'No name'
    if code == gi.SKIP_INDEX_RANGE:
        return f'Index {fmt_index(item.row.index)} out of range'
    if code == gi.SKIP_ALREADY_MATCHED:
        return f'Already matched to {(item.detail or {}).get("player_name", "")}'
    return item.reason.capitalize()


def view(plan: gi.ImportPlan, overrides: dict | None = None) -> dict:
    """The whole plan, shaped for the preview template."""
    overrides = overrides or {}

    creates = [{
        'line':     r.line,
        'name':     r.name,
        'index':    fmt_index(r.index),
        'is_plus':  is_plus(r.index),
        'ghin':     r.ghin or '—',
        'phone':    fmt_phone(r.phone or ''),
        'td_index': r.td_index,
        # A golfer created without a phone has no way to claim their record
        # later, which is worth one quiet line rather than a warning.
        'note': ('index you typed' if r.td_index
                 else 'no phone — cannot claim yet' if not r.phone
                 else 'plus handicap' if is_plus(r.index) else ''),
    } for r in plan.to_create]

    updates = [{
        'line':        u.row.line,
        'name':        u.player_name,
        'matched_by':  u.matched_by,
        'diffs':       [_diff(f, u.before.get(f), u.changes[f])
                        for f in _ordered(u.changes)],
        'conflict':    fmt_phone(u.phone_conflict) if u.phone_conflict else '',
    } for u in plan.to_update]

    skips = [{
        'line':     s.row.line,
        # A row with no name still needs something to point at, and the source
        # line is the only handle the TD has back to the spreadsheet.
        'name':     s.row.name or f'(row {s.row.line})',
        'reason':   _skip_reason(s),
        'detail':   _skip_detail(s),
        'code':     s.code,
        # Only "new golfer has no index" is the TD's problem to solve here.  A
        # TD inventing a name for row 41 is worse than a skip, so the rest stay
        # read-only rather than merely discouraged.
        'fixable':  s.code in gi.SKIP_FIXABLE,
        'is_file_error': s.code in (gi.SKIP_NO_NAME, gi.SKIP_INDEX_RANGE),
        'typed':    overrides.get(str(s.row.line), ''),
    } for s in plan.skipped]

    unchanged = [{
        'line':  r.line,
        'name':  r.name,
        'index': fmt_index(r.index),
    } for r in plan.unchanged]

    fixable = sum(1 for s in skips if s['fixable'])
    return {
        'creates':   creates,
        'updates':   updates,
        'skips':     skips,
        'unchanged': unchanged,
        'counts': {
            'create':    len(creates),
            'update':    len(updates),
            'unchanged': len(unchanged),
            'skipped':   len(skips),
            'fixable':   fixable,
            'td_index':  sum(1 for c in creates if c['td_index']),
        },
    }


def change_log(plan: gi.ImportPlan) -> dict:
    """What the apply actually wrote, stored on the run.

    Also everything a per-run reversal would need: the created ids to delete,
    and the before-values to put back.  There is no undo today — the importer
    has none — so this is a record, not a promise.
    """
    return {
        'created': [
            {'player_id': pid, 'line': r.line, 'name': r.name,
             'index': str(r.index), 'td_index': r.td_index}
            for pid, r in zip(plan.created_ids, plan.to_create)
        ],
        'updated': [
            {'player_id': u.player_id, 'line': u.row.line, 'name': u.player_name,
             'matched_by': u.matched_by,
             'before': {k: str(v) for k, v in u.before.items()},
             'after':  {k: str(v) for k, v in u.changes.items()}}
            for u in plan.to_update
        ],
        'skipped': [
            {'line': s.row.line, 'name': s.row.name,
             'reason': _skip_reason(s), 'detail': _skip_detail(s),
             'code': s.code}
            for s in plan.skipped
        ],
        'unchanged': [{'line': r.line, 'name': r.name} for r in plan.unchanged],
    }


def receipt_updates(log: dict) -> list[dict]:
    """The stored change log, re-shaped for the receipt.

    The log holds raw field names and stringified values because it is a
    record, not a view.  This is where they become ``idx 8.4 → 7.9`` again —
    the receipt should read like the preview it followed, and no field name
    reaches a template as ``handicap_index``.
    """
    out = []
    for u in log.get('updated', []):
        before, after = u.get('before', {}), u.get('after', {})
        out.append({
            'line':       u.get('line'),
            'name':       u.get('name'),
            'matched_by': u.get('matched_by', ''),
            'diffs':      [_diff(f, before.get(f) or '', after[f])
                           for f in _ordered(after)],
        })
    return out
