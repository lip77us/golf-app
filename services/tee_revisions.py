"""
services/tee_revisions.py
-------------------------
Copy-on-write for account Tee geometry, so a round's scorecard stays frozen
against the hole data (par + stroke index) it was actually played on.

Every scoring service reads par / stroke index LIVE from `membership.tee.holes`
(e.g. points_531, skins, nassau, sixes …).  So mutating a Tee's holes in place
would retroactively rewrite the net scores and handicap allocations of every
completed round on that tee.  `update_tee_geometry()` prevents that:

  * If the new holes differ AND the tee is already referenced by a
    FoursomeMembership, the old row is RETIRED (`Tee.superseded_by`) and a NEW
    current revision is created — rounds already played keep pointing at the
    old, now-immutable row; new rounds pick up the re-rate.
  * Otherwise (unreferenced, or holes unchanged) the row updates IN PLACE, so a
    course nobody has played yet doesn't accumulate revisions.

This is the single choke point every geometry writer goes through: the manual
paste editor (services/course_paste.py) and the catalog re-import / refresh
(services/catalog.py).
"""
from core.models import Tee

# Fields that make up a tee's "geometry" — everything a re-rate may change.
_GEOMETRY_FIELDS = ('tee_name', 'slope', 'course_rating', 'par', 'sex',
                    'holes', 'sort_priority')


def _tee_is_referenced(tee) -> bool:
    """True if any FoursomeMembership points at this tee (i.e. it's been used
    in a round and its hole data must not change underneath it)."""
    from tournament.models import FoursomeMembership
    return FoursomeMembership.objects.filter(tee=tee).exists()


def update_tee_geometry(tee, attrs: dict):
    """Apply `attrs` (a subset of `_GEOMETRY_FIELDS`) to `tee`, preserving the
    hole data of any round already played on it.

    Returns the CURRENT Tee after the update: the same row updated in place when
    safe, or a freshly-created replacement revision when the holes changed on an
    already-referenced tee.  Local preferences (sort_priority) are carried onto
    the replacement unless `attrs` overrides them.
    """
    new_holes = attrs.get('holes', tee.holes)
    holes_changed = new_holes != tee.holes

    if holes_changed and _tee_is_referenced(tee):
        replacement = Tee.objects.create(
            course        = tee.course,
            tee_name      = attrs.get('tee_name',      tee.tee_name),
            slope         = attrs.get('slope',         tee.slope),
            course_rating = attrs.get('course_rating', tee.course_rating),
            par           = attrs.get('par',           tee.par),
            sex           = attrs.get('sex',           tee.sex),
            holes         = new_holes,
            sort_priority = attrs.get('sort_priority', tee.sort_priority),
        )
        tee.superseded_by = replacement
        tee.save(update_fields=['superseded_by'])
        return replacement

    for field in _GEOMETRY_FIELDS:
        if field in attrs:
            setattr(tee, field, attrs[field])
    tee.save()
    return tee
