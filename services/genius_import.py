"""
services/genius_import.py
-------------------------
Import a **Golf Genius roster export** (``.xlsx`` or ``.csv``) into an
account's ``Player`` roster.

Golf Genius exports a wide sheet (name, email, index, GHIN, DOB, city, tee, …);
we consume only the handful of columns that map onto our ``Player`` model and
ignore the rest.  The header row is NOT necessarily the first row — Golf Genius
prefixes a title banner — so we scan for the row that carries "First Name" and
"Last Name".

Matching:  each incoming row is matched to an existing account ``Player`` by
**normalized phone** (the app's cross-account identity key), falling back to
**GHIN**.  A match updates the golfer's index + GHIN (+ email/sex if blank); no
match creates a login-less ``Player``.

Two phases so a caller can preview before committing:
    rows          = read_rows(filename, data)          # raw list-of-lists
    parsed, hdr   = parse_rows(rows)                    # normalized + validated
    plan          = build_plan(account, parsed)         # diff, no writes
    created, upd  = apply_plan(account, plan)           # commit (atomic)

The reader is intentionally **dependency-free** (stdlib ``zipfile`` + XML for
xlsx) so the import runs with no extra pip installs; swap in ``openpyxl`` later
if richer parsing is needed.

Django is only touched inside ``build_plan`` / ``apply_plan`` (model access) —
the parsing half imports cleanly without ``django.setup()`` so it can be
unit-tested in isolation.
"""

from __future__ import annotations

import csv
import io
import re
import zipfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from decimal import Decimal, InvalidOperation

from accounts.phone import normalize as normalize_phone

# --- Golf Genius column headers we consume (matched case-insensitively) -------
COL_FIRST  = 'first name'
COL_LAST   = 'last name'
COL_INDEX  = 'index'
COL_GHIN   = 'ghin id'
COL_PHONE  = 'phone number'
COL_EMAIL  = 'email'
COL_GENDER = 'gender'

# Model bounds — mirror Player.handicap_index validators.
INDEX_MIN = Decimal('-10')
INDEX_MAX = Decimal('54')

_SML = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'


# ---------------------------------------------------------------------------
# Readers  (filename -> list[list[str]])
# ---------------------------------------------------------------------------

def read_rows(filename: str, data: bytes) -> list[list[str]]:
    """Dispatch on extension and return a list of rows (each a list of cell
    strings).  Supports ``.csv`` and ``.xlsx``."""
    lower = (filename or '').lower()
    if lower.endswith('.csv'):
        return _rows_from_csv(data)
    if lower.endswith('.xlsx'):
        return _rows_from_xlsx(data)
    raise ValueError('Unsupported file type — use a .csv or .xlsx export.')


def _rows_from_csv(data: bytes) -> list[list[str]]:
    text = data.decode('utf-8-sig', errors='replace')
    return [[(c or '').strip() for c in row] for row in csv.reader(io.StringIO(text))]


def _col_number(ref: str) -> int:
    """'C7' -> 2 (zero-based column index)."""
    letters = re.match(r'[A-Z]+', ref or 'A').group()
    n = 0
    for ch in letters:
        n = n * 26 + (ord(ch) - 64)
    return n - 1


def _rows_from_xlsx(data: bytes) -> list[list[str]]:
    """Minimal xlsx reader — handles both shared-string and inline-string
    storage.  Reads the first worksheet only."""
    z = zipfile.ZipFile(io.BytesIO(data))

    shared: list[str] = []
    try:
        sst = ET.fromstring(z.read('xl/sharedStrings.xml'))
        for si in sst:
            shared.append(''.join(t.text or '' for t in si.iter(_SML + 't')))
    except KeyError:
        pass  # inline strings only

    sheet = ET.fromstring(z.read('xl/worksheets/sheet1.xml'))
    rows: list[list[str]] = []
    for r in sheet.iter(_SML + 'row'):
        cells: dict[int, str] = {}
        maxc = -1
        for c in r:
            ci = _col_number(c.get('r') or 'A')
            inline = c.find(_SML + 'is')
            if inline is not None:
                val = ''.join(x.text or '' for x in inline.iter(_SML + 't'))
            else:
                v = c.find(_SML + 'v')
                if v is None:
                    val = ''
                elif c.get('t') == 's':
                    val = shared[int(v.text)]
                else:
                    val = v.text or ''
            cells[ci] = (val or '').strip()
            maxc = max(maxc, ci)
        rows.append([cells.get(i, '') for i in range(maxc + 1)])
    return rows


# ---------------------------------------------------------------------------
# Parsing  (rows -> ParsedRow[])
# ---------------------------------------------------------------------------

@dataclass
class ParsedRow:
    line: int                       # 1-based source row number (for messages)
    name: str
    email: str
    phone_raw: str
    phone: str | None               # normalized E.164, or None
    ghin: str
    sex: str                        # 'M' | 'W'
    index: Decimal | None
    error: str | None = None        # set => fatal, row is skipped


def _header_map(header: list[str]) -> dict[str, int]:
    return {(h or '').strip().lower(): i for i, h in enumerate(header)}


def _find_header(rows: list[list[str]]) -> tuple[int, dict[str, int]]:
    for i, row in enumerate(rows):
        labels = {(c or '').strip().lower() for c in row}
        if COL_FIRST in labels and COL_LAST in labels:
            return i, _header_map(row)
    raise ValueError(
        "Couldn't find a header row containing 'First Name' and 'Last Name' — "
        "is this a Golf Genius roster export?"
    )


def _cell(row: list[str], hmap: dict[str, int], key: str) -> str:
    i = hmap.get(key)
    if i is None or i >= len(row):
        return ''
    return (row[i] or '').strip()


def parse_index(raw: str) -> Decimal | None:
    """Parse a Golf Genius index cell into a Decimal.

    Handles plus-handicaps ('+2.3' => -2.3, i.e. better than scratch) and the
    common no-handicap sentinels ('NH', 'N/A', 'WD', blank) => None.
    """
    if not raw:
        return None
    s = raw.strip().upper().replace(' ', '')
    if s in ('NH', 'N/A', 'NA', 'WD', '-', '--'):
        return None
    neg = s.startswith('+')          # plus handicap is BELOW scratch
    s = s.lstrip('+')
    try:
        val = Decimal(s)
    except InvalidOperation:
        return None
    return -val if neg else val


def parse_rows(rows: list[list[str]]) -> tuple[list[ParsedRow], dict[str, int]]:
    """Locate the header and normalize/validate each data row.  Returns
    ``(parsed_rows, header_map)``.  Rows with a fatal problem carry ``.error``
    and are excluded from create/update by ``build_plan``."""
    header_idx, hmap = _find_header(rows)
    parsed: list[ParsedRow] = []

    for offset, row in enumerate(rows[header_idx + 1:], start=header_idx + 2):
        if not any((c or '').strip() for c in row):
            continue  # blank line

        first = _cell(row, hmap, COL_FIRST)
        last  = _cell(row, hmap, COL_LAST)
        name  = ' '.join(p for p in (first, last) if p).strip()

        phone_raw = _cell(row, hmap, COL_PHONE)
        ghin_raw  = _cell(row, hmap, COL_GHIN)
        gender    = _cell(row, hmap, COL_GENDER).upper()

        pr = ParsedRow(
            line=offset,
            name=name,
            email=_cell(row, hmap, COL_EMAIL),
            phone_raw=phone_raw,
            phone=normalize_phone(phone_raw),
            ghin=re.sub(r'\D', '', ghin_raw),        # digits only
            sex='W' if gender.startswith('F') else 'M',
            index=parse_index(_cell(row, hmap, COL_INDEX)),
        )

        if not name:
            pr.error = 'no name'
        elif pr.index is not None and not (INDEX_MIN <= pr.index <= INDEX_MAX):
            pr.error = f'index {pr.index} out of range ({INDEX_MIN}..{INDEX_MAX})'
        parsed.append(pr)

    return parsed, hmap


# ---------------------------------------------------------------------------
# Planning  (account + parsed -> ImportPlan)   — no writes
# ---------------------------------------------------------------------------

@dataclass
class UpdateItem:
    row: ParsedRow
    player_id: int
    player_name: str
    changes: dict            # field -> new value


@dataclass
class SkipItem:
    row: ParsedRow
    reason: str


@dataclass
class ImportPlan:
    to_create: list[ParsedRow] = field(default_factory=list)
    to_update: list[UpdateItem] = field(default_factory=list)
    unchanged: list[ParsedRow] = field(default_factory=list)
    skipped:   list[SkipItem]  = field(default_factory=list)

    def summary(self) -> dict:
        return {
            'create':    len(self.to_create),
            'update':    len(self.to_update),
            'unchanged': len(self.unchanged),
            'skipped':   len(self.skipped),
        }


def build_plan(account, parsed: list[ParsedRow]) -> ImportPlan:
    """Diff the parsed rows against the account's existing roster.  Pure read —
    no database writes."""
    from core.models import Player

    existing = list(Player.objects.filter(account=account, is_phantom=False))
    by_phone: dict[str, Player] = {}
    by_ghin: dict[str, Player] = {}
    for p in existing:
        np = normalize_phone(p.phone)
        if np:
            by_phone.setdefault(np, p)
        if p.ghin:
            by_ghin.setdefault(p.ghin, p)

    plan = ImportPlan()
    seen_phone: set[str] = set()
    seen_ghin: set[str] = set()
    matched_ids: set[int] = set()

    for row in parsed:
        if row.error:
            plan.skipped.append(SkipItem(row, row.error))
            continue

        # Duplicate rows within the same file (same identity) — import once.
        if row.phone and row.phone in seen_phone:
            plan.skipped.append(SkipItem(row, 'duplicate phone in file'))
            continue
        if row.ghin and row.ghin in seen_ghin:
            plan.skipped.append(SkipItem(row, 'duplicate GHIN in file'))
            continue
        if row.phone:
            seen_phone.add(row.phone)
        if row.ghin:
            seen_ghin.add(row.ghin)

        match = (row.phone and by_phone.get(row.phone)) or \
                (row.ghin and by_ghin.get(row.ghin)) or None

        if match is None:
            if row.index is None:
                plan.skipped.append(SkipItem(row, 'new golfer has no index'))
            else:
                plan.to_create.append(row)
            continue

        if match.id in matched_ids:
            plan.skipped.append(SkipItem(row, f'already matched to {match.name}'))
            continue
        matched_ids.add(match.id)

        changes: dict = {}
        if row.index is not None and row.index != match.handicap_index:
            changes['handicap_index'] = row.index
        if row.ghin and row.ghin != match.ghin:
            changes['ghin'] = row.ghin
        if row.email and not match.email:
            changes['email'] = row.email
        # Backfill phone only when the existing copy has none (never clobber an
        # already-linked number — the match may have come via GHIN).
        if row.phone and not normalize_phone(match.phone):
            changes['phone'] = row.phone

        if changes:
            plan.to_update.append(
                UpdateItem(row, match.id, match.name, changes))
        else:
            plan.unchanged.append(row)

    return plan


# ---------------------------------------------------------------------------
# Apply  (account + plan -> counts)   — atomic
# ---------------------------------------------------------------------------

def apply_plan(account, plan: ImportPlan) -> tuple[int, int]:
    """Commit the plan.  Returns ``(created, updated)``.  Wrapped in a single
    transaction so a mid-import failure rolls back cleanly."""
    from django.db import transaction
    from core.models import Player

    created = updated = 0
    with transaction.atomic():
        for row in plan.to_create:
            Player.objects.create(
                account=account,
                name=row.name,
                email=row.email,
                phone=row.phone or row.phone_raw or '',
                ghin=row.ghin,
                sex=row.sex,
                handicap_index=row.index,
            )
            created += 1

        for item in plan.to_update:
            player = Player.objects.get(pk=item.player_id)
            for f, v in item.changes.items():
                setattr(player, f, v)
            player.save()
            updated += 1

    return created, updated
