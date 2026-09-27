"""Who is actually running Halved on Android?

Play Console will not tell you WHICH testers opted in — only a count. This
reports what your own data knows, which is a stricter signal: a golfer only
appears here if they installed, opened the app, signed in, and allowed
notifications. So a name here definitely counts toward the 12; a name MISSING
may still have opted in (opt-in != install != sign-in != notifications).

Run against prod:

    railway ssh "/opt/venv/bin/python manage.py shell" < scripts/android_testers.py

**Not `railway run`.** That runs on YOUR machine with prod's env injected, and
`DATABASE_URL` names `postgres.railway.internal` — a private hostname that only
resolves inside Railway's network, so it dies with "could not translate host
name". `railway ssh` runs inside the container, where it does resolve. The
container's Django lives in `/opt/venv`, not on the default PATH, so the full
interpreter path is required. stdin is forwarded, hence the `<`.

Locally: `poetry run python manage.py shell < scripts/android_testers.py`
(the repo has no `.venv`; Django is in poetry's virtualenv).
"""

from datetime import datetime, timezone

from accounts.models import DeviceToken, User
from accounts.phone import normalize
from core.models import Player

# Closed testing - Alpha went live 19 Sep 2026. Activity older than this
# cannot be a closed-test install.
CLOSED_TRACK_OPENED = datetime(2026, 9, 19, tzinfo=timezone.utc)

# The Play closed-track tester list (Test and release -> Closed testing ->
# Manage track -> Testers -> the arrow beside the list name).
TESTER_EMAILS = [
    "Epstein837@gmail.com",
    "Igorkipnis@gmail.com",
    "Jv1234.jv1234@gmail.com",
    "cwoakland@gmail.com",
    "drum77@yahoo.com",
    "hingwah54@gmail.com",
    "joliver310@gmail.com",
    "lip77us@gmail.com",
    "ofd2548@hotmail.com",
    "ooi.leng.lum@gmail.com",
    "paul@lipkin.us",
    "rfelix099@gmail.com",
]


def _name_for(user):
    """Best available human name for a User."""
    p = Player.objects.filter(user=user).first()
    return (p.name if p else None) or user.get_username()


def _note(user, updated_at):
    """Flag rows that are NOT a real tester who joined the closed test.

    Two kinds turned up on the first prod run and both read as testers
    otherwise: the `seed_demo` reviewer block, and golfers whose last activity
    predates the closed track (leftover internal-testing installs).
    """
    notes = []
    phone = (user.phone or "")
    if phone.startswith("+1310555010"):
        notes.append("seed_demo account, not a golfer")
    if updated_at < CLOSED_TRACK_OPENED:
        notes.append("predates the closed track — internal-testing leftover")
    return "  <- " + "; ".join(notes) if notes else ""


def main():
    line = "=" * 64

    # ---- 1. Android devices seen -------------------------------------
    print(line)
    print("ANDROID DEVICES SEEN (installed + signed in + notifications on)")
    print(line)
    rows = (DeviceToken.objects
            .filter(platform="android")
            .select_related("user")
            .order_by("-updated_at"))
    if not rows:
        print("  none yet")
    seen_users = set()
    for d in rows:
        if d.user_id in seen_users:
            continue          # one line per person, newest device first
        seen_users.add(d.user_id)
        print(f"  {_name_for(d.user):<24} {d.user.phone or '(no phone)':<16} "
              f"last seen {d.updated_at:%Y-%m-%d %H:%M}"
              f"{_note(d.user, d.updated_at)}")
    print(f"\n  {len(seen_users)} distinct golfer(s) on Android")

    # ---- 2. Platform split -------------------------------------------
    print()
    print(line)
    print("PLATFORM SPLIT (all device tokens)")
    print(line)
    for plat in ("android", "ios", ""):
        n = DeviceToken.objects.filter(platform=plat).values("user").distinct().count()
        print(f"  {plat or '(unset)':<10} {n} golfer(s)")

    # ---- 3. Tester list -> does that person have a Halved account? ----
    print()
    print(line)
    print("PLAY TESTER LIST vs HALVED ACCOUNTS")
    print(line)
    print("  Matched by email. A tester with no Halved account may still have")
    print("  opted in on Play — this only says whether they have signed up.\n")
    android_user_ids = set(
        DeviceToken.objects.filter(platform="android")
        .values_list("user_id", flat=True))
    for email in TESTER_EMAILS:
        e = email.strip().lower()
        user = User.objects.filter(email__iexact=e).first()
        if user is None:
            player = Player.objects.filter(email__iexact=e).exclude(user=None).first()
            user = player.user if player else None
        if user is None:
            print(f"  {email:<26} no Halved account found")
        else:
            flag = "ANDROID" if user.id in android_user_ids else "signed up"
            print(f"  {email:<26} {flag:<10} {_name_for(user)}")

    print()
    print(line)
    print("Play shows only a COUNT (Dashboard -> Production). To learn who has")
    print("opted in but not installed, you have to ask them.")
    print(line)


main()
