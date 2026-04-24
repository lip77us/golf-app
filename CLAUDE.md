This is a golf app that will support tracking golf gambling games for golfers during the round.

I plan to eventually support tournaments that might have multiple foursomes, multiple games being played at the same time and potentially multiple rounds across multiple days where the user can pick the best N of the M rounds.

I will start by implementing some single foursome games where there is no greater tournament and it concludes after the single 18 hole round.  This is called a casual round and is not really part of a specific tournament.

I have decided to put in three modes to operate on single foursome games.  You could go net (with a percentage of net), or gross, Strokes off best golfer.   We can play all three depending on the situation.  I want to define for each game, if all three are possible.  Sometimes, only net or only strokes off makes sense, depending on the game.

---

## Architecture overview

**Stack:** Django REST Framework backend + Flutter/Dart mobile app.

**Key directories:**
- `backend/core/` — shared enums (GameType, MatchStatus, HandicapMode), Player model
- `backend/games/` — per-game models (SkinsGame, SkinsHoleResult, SkinsPlayerHoleResult, Points531Game, etc.), migrations
- `backend/services/` — business logic (skins.py, points_531.py, sixes.py …)
- `backend/api/` — serializers.py, views.py, urls.py
- `mobile/lib/api/` — models.dart, client.dart
- `mobile/lib/providers/` — round_provider.dart (main state), auth_provider.dart
- `mobile/lib/screens/` — one screen file per game

**Coding pattern:** Every new game follows the Points 5-3-1 pattern exactly (use that as the template for future games).

---

## Implemented casual games

### Six's (`sixes`)
- 2v2 best-ball across three 6-hole segments, requires exactly 4 players.
- Setup screen: `/sixes-setup` → `SixesSetupScreen`; play screen: `/sixes` → `SixesScreen`

### Points 5-3-1 (`points_531`)
- Per-player points game, requires exactly 3 players.
- Setup screen: `/points-531-setup` → `Points531SetupScreen`; play screen: `/points-531` → `Points531Screen`

### Skins (`skins`) — **fully implemented, not yet tested in production**
- 2–4 players; 1 skin per hole to best score; optional carryover on ties; optional junk skins (manual integer count per player per hole); pool-based settlement (bet_unit × n_players, split proportional to total_skins).
- Handicap: Net / Gross / Strokes-Off-Low (all three supported).
- Mutually exclusive with all other casual games.

**Backend files changed/created:**
- `backend/core/models.py` — added `SKINS = 'skins'` to GameType enum
- `backend/games/models.py` — added `SkinsGame`, `SkinsHoleResult`, `SkinsPlayerHoleResult`
- `backend/games/migrations/0004_skins.py` — migration for the three new tables
- `backend/services/skins.py` — `setup_skins()`, `calculate_skins()`, `skins_summary()`
- `backend/api/serializers.py` — `SkinsSetupSerializer`, `SkinsJunkSerializer`, `SkinsJunkEntrySerializer`
- `backend/api/views.py` — `SkinsSetupView` (POST), `SkinsResultView` (GET), `SkinsJunkView` (POST); also fixed `_build_leaderboard()` to use `skins_summary(fs)` directly (not wrapped in `{'totals': ...}`)
- `backend/api/urls.py` — three new routes under `foursomes/<pk>/skins/`

**Mobile files changed/created:**
- `mobile/lib/api/models.dart` — `SkinsSummary`, `SkinsPlayerTotal`, `SkinsHole`, `SkinsJunkEntry`
- `mobile/lib/api/client.dart` — `getSkinsSummary()`, `postSkinsSetup()`, `postSkinsJunk()`
- `mobile/lib/providers/round_provider.dart` — `skinsSummary`, `loadingSkins`, `loadSkins()`
- `mobile/lib/screens/skins_setup_screen.dart` — new (setup knobs: handicap mode, carryover, junk, bet unit)
- `mobile/lib/screens/skins_screen.dart` — new (score entry + junk stepper + hole outcome strip + 18-hole grid)
- `mobile/lib/screens/leaderboard_screen.dart` — updated `_SkinsGroupCard` to use new summary shape (`players`, `money` keys)
- `mobile/lib/screens/casual_round_screen.dart` — enabled Skins chip, added to mutex group, added 2–4 player gate + inline warning, added `/skins-setup` routing branch
- `mobile/lib/screens/round_screen.dart` — added `skins` branch in `onEnterScores` routing
- `mobile/lib/main.dart` — added imports + `/skins-setup` and `/skins` route registrations

**API shape (skins summary):**
```json
{
  "status": "in_progress",
  "handicap_mode": "net",
  "net_percent": 100,
  "carryover": true,
  "allow_junk": false,
  "players": [
    {"player_id": 1, "name": "Paul", "short_name": "Paul",
     "skins_won": 3, "junk_skins": 1, "total_skins": 4, "payout": 12.00}
  ],
  "holes": [
    {"hole": 1, "winner_id": 1, "winner_short": "Paul",
     "skins_value": 1, "is_carry": false,
     "junk": [{"player_id": 1, "short_name": "Paul", "count": 1}]}
  ],
  "money": {"bet_unit": 1.00, "pool": 4.00, "total_skins": 4}
}
```

**Endpoints:**
- `GET  /api/foursomes/<id>/skins/`        → skins summary
- `POST /api/foursomes/<id>/skins/setup/`  → configure + start (body: handicap_mode, net_percent, carryover, allow_junk)
- `POST /api/foursomes/<id>/skins/junk/`   → upsert junk counts (body: hole_number, junk_entries: [{player_id, junk_count}])

---

## Nassau — not yet implemented
Reserved chip in the casual-round picker but disabled. When implementing, follow the Skins/Points 5-3-1 pattern.