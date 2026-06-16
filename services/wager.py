"""
services/wager.py
-----------------
Pure, DB-free wager settlement core for the wager wizard
(see docs/wager-wizard.md).

Turns per-side points/scores into per-side money via a normalized
``WagerConfig``, applying the table-wide per-side loss cap (clip the
losers at the cap, rescale the winners pro-rata so the table stays
zero-sum).

**Side-keyed throughout.** A *side* is one player in an individual game,
a team in a team game.  Individual games are the degenerate
one-player-per-side case, so callers that don't have teams just pass
``{player_id: points}``.

No Django imports — this is unit-testable in isolation and is the single
source of truth for payout math across every points game.

Settlement formulas (all zero-sum):

* ``proportional`` (pool) — each side antes ``entry``; the pool
  (``entry × n``) is split by each side's share of total points.  A
  side's max loss is its entry, so pool games need no cap (the entry
  *is* the cap).
* ``vs_average`` (per-point, **standard**) — ``(side_points − baseline)
  × rate`` where ``baseline = total_points / n``.  This is exactly the
  existing Points 5-3-1 economics: 5-3-1 hardcodes ``baseline`` as
  ``3 × holes`` because it always awards 9 points/hole among 3 players;
  here the baseline is computed so it generalizes to variable-total
  games (custom Stableford tables, Wolf, Vegas).
* ``pay_above`` (per-point, advanced) — "pay everyone above you the
  difference."  Full pairwise: ``(n × side_points − total) × rate``,
  which is identically ``n × vs_average`` — same ranking, n× the
  magnitude.
* ``pay_winner`` (per-point, advanced) — only the leader(s) are paid;
  each other side pays the leader the point difference (split among
  tied leaders).
"""
from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal, ROUND_HALF_UP
from typing import Mapping, Optional

CENT = Decimal("0.01")

# --- Funding ---------------------------------------------------------------
POOL = "pool"
PER_POINT = "per_point"
FUNDINGS = {POOL, PER_POINT}

# --- Settlement ------------------------------------------------------------
PROPORTIONAL = "proportional"   # pool
VS_AVERAGE = "vs_average"       # per-point, STANDARD (Points 5-3-1 economics)
PAY_WINNER = "pay_winner"       # per-point, advanced (only the leader is paid)
PAY_ABOVE = "pay_above"         # per-point, advanced (pay everyone above you)
PER_POINT_SETTLEMENTS = {VS_AVERAGE, PAY_WINNER, PAY_ABOVE}


def _dec(v) -> Decimal:
    """Coerce int/float/str/Decimal/None → Decimal (None → 0)."""
    if v is None:
        return Decimal("0")
    if isinstance(v, Decimal):
        return v
    return Decimal(str(v))


@dataclass(frozen=True)
class WagerConfig:
    """
    Normalized wager configuration shared by every points game.

    Superset of the existing Stableford fields:
        funding   ← payout_style ('pool' | 'per_point')
        rate      ← per_point_rate
        pay_above ← per_point_mode='all'
        pay_winner← per_point_mode='first'
    New: ``vs_average`` settlement and ``cap``.

    ``cap`` is carried independently of settlement so games with native
    settlement (Nassau pots, Skins per-hole, Sixes segments) can use a
    cap — or a derived read-only max — without touching the Axis-2 menu.
    """

    funding: str
    settlement: str
    entry: Optional[Decimal] = None     # pool only — per-side ante (its own cap)
    rate: Optional[Decimal] = None      # per-point only — $/point
    cap: Optional[Decimal] = None       # per-point only — per-side loss cap

    def __post_init__(self):
        if self.funding not in FUNDINGS:
            raise ValueError(f"unknown funding {self.funding!r}")
        if self.funding == POOL:
            if self.settlement != PROPORTIONAL:
                raise ValueError("pool funding requires settlement='proportional'")
            if self.entry is None:
                raise ValueError("pool funding requires an entry")
        else:  # PER_POINT
            if self.settlement not in PER_POINT_SETTLEMENTS:
                raise ValueError(
                    f"per_point funding requires settlement in {PER_POINT_SETTLEMENTS}"
                )
            if self.rate is None:
                raise ValueError("per_point funding requires a rate")
        if self.cap is not None and _dec(self.cap) < 0:
            raise ValueError("cap must be non-negative")


# ---------------------------------------------------------------------------
# Public entry point
# ---------------------------------------------------------------------------
def settle(points_by_side: Mapping, config: WagerConfig) -> dict:
    """
    Settle a finished (or in-progress) game.

    ``points_by_side`` : ``{side_id: points}`` (points int/float/Decimal).
    Returns ``{side_id: net_money}`` as cent-quantized ``Decimal``, where
    positive = receives, negative = pays.  The result always sums to
    exactly ``0`` (zero-sum), penny residue reconciled.
    """
    pts = {s: _dec(p) for s, p in points_by_side.items()}

    if config.funding == POOL:
        raw = _proportional(pts, config)
        return _quantize_zero_sum(raw)

    raw = _raw_per_point(pts, config)
    capped = _apply_cap(raw, config.cap)
    return _quantize_zero_sum(capped)


# ---------------------------------------------------------------------------
# Raw (uncapped) settlement formulas — each returns a zero-sum signed dict
# ---------------------------------------------------------------------------
def _proportional(pts: dict, config: WagerConfig) -> dict:
    """Pool: split ``entry × n`` by share of points; each side nets share − ante."""
    entry = _dec(config.entry)
    total = sum(pts.values())
    if total <= 0:
        # No points scored anywhere → everyone just gets their ante back.
        return {s: Decimal("0") for s in pts}
    pool = entry * len(pts)
    return {s: pool * (p / total) - entry for s, p in pts.items()}


def _raw_per_point(pts: dict, config: WagerConfig) -> dict:
    rate = _dec(config.rate)
    n = len(pts)
    total = sum(pts.values())

    if config.settlement == VS_AVERAGE:
        baseline = total / n
        return {s: (p - baseline) * rate for s, p in pts.items()}

    if config.settlement == PAY_ABOVE:
        # Full pairwise == n × vs_average.
        return {s: (n * p - total) * rate for s, p in pts.items()}

    if config.settlement == PAY_WINNER:
        win_pts = max(pts.values())
        winners = [s for s, p in pts.items() if p == win_pts]
        raw = {s: Decimal("0") for s in pts}
        pot = Decimal("0")
        for s, p in pts.items():
            if p < win_pts:
                owed = (win_pts - p) * rate
                raw[s] = -owed
                pot += owed
        share = pot / len(winners)
        for w in winners:
            raw[w] = share
        return raw

    raise ValueError(f"unknown settlement {config.settlement!r}")


# ---------------------------------------------------------------------------
# Cap: clip losers at the cap, rescale winners pro-rata to rebalance
# ---------------------------------------------------------------------------
def _apply_cap(raw: dict, cap) -> dict:
    """
    Apply a per-side loss cap.  Losing sides clip at ``cap``; the
    resulting shortfall reduces winning sides in proportion to what each
    was owed (pro-rata), keeping the table zero-sum.

    ``cap=None`` → unbounded (returns ``raw`` unchanged).
    """
    if cap is None:
        return dict(raw)
    cap = _dec(cap)

    collected = Decimal("0")   # what losers actually pay after clipping
    owed = Decimal("0")        # what winners were originally owed
    clipped = {}
    for s, amt in raw.items():
        if amt < 0:
            loss = min(-amt, cap)
            clipped[s] = -loss
            collected += loss
        else:
            owed += amt

    if owed == 0:
        # Nobody to pay (all sides ≤ 0) — return clipped losers + zeros.
        return {s: (clipped[s] if raw[s] < 0 else Decimal("0")) for s in raw}

    factor = collected / owed   # ≤ 1
    out = {}
    for s, amt in raw.items():
        out[s] = amt * factor if amt > 0 else clipped.get(s, Decimal("0"))
    return out


# ---------------------------------------------------------------------------
# Quantize to cents while preserving the zero-sum invariant
# ---------------------------------------------------------------------------
def _quantize_zero_sum(raw: dict) -> dict:
    """
    Round each side to cents; distribute any penny residue (from
    division/rescaling) by largest rounding remainder so the result
    still sums to exactly 0.
    """
    q = {s: raw[s].quantize(CENT, rounding=ROUND_HALF_UP) for s in raw}
    residual = -sum(q.values())          # exact sum is 0, so this is the drift
    if residual == 0 or not q:
        return q

    cents = int((abs(residual) / CENT).to_integral_value())
    step = CENT if residual > 0 else -CENT
    # Hand pennies to the sides we rounded away from the most in the
    # needed direction (largest-remainder method).
    order = sorted(raw, key=lambda s: (raw[s] - q[s]), reverse=(residual > 0))
    for i in range(cents):
        q[order[i % len(order)]] += step
    return q
