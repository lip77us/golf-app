#!/bin/sh
# The newest receipt, or the newest for a named round: `scripts/receipt.sh 583`.
# Prints the link and the rows, so there is no round number to look up.
cd "$(dirname "$0")/.." || exit 1
exec /Users/paullipkin/Library/Caches/pypoetry/virtualenvs/golf-app-7K31Q_ra-py3.12/bin/python -P - "$@" <<'PY'
import sys; sys.path.insert(0, '.')
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'my_golf_app.settings')
django.setup()
from tournament.models import Receipt

qs = Receipt.objects.all()
if len(sys.argv) > 1:
    qs = qs.filter(round_id=int(sys.argv[1]))
r = qs.first()
if not r:
    print('no receipt yet — finish a round first'); raise SystemExit(1)
p = r.payload or {}
print(f'{p.get("title")}  ·  round {r.round_id}  ·  settled {r.created_at:%H:%M %d %b}')
print(f'http://localhost:8000/r/{r.code}/')
for s in (p.get('webGames') or p.get('games') or []):
    print(f'\n  {s["label"].upper()}')
    for label, value in s['rows']:
        print(f'    {label:<22} {value}')
print()
PY
