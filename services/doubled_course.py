"""
services/doubled_course.py
--------------------------
Play a NINE-hole course twice and have it look like an 18-hole one.

The app's scoring reads par and stroke index off a tee's hole list and takes the
hole universe from the course's tees, so the least invasive way to play a nine
twice is to hand it an 18-hole course: nothing downstream changes, and every
game that needs eighteen holes (Nassau, Sixes, the bracket) works.

``get_or_create_doubled_course(course)`` returns an account-private 18-hole
course, ``Course.doubled_of = course``, with one doubled tee per current tee of
the nine:

* holes 10–18 repeat holes 1–9 (same par and yardage);
* **stroke index**: the first nine takes the odd indexes and the second the even
  ones (``2·si − 1`` then ``2·si``), so a stroke lands on the hardest hole of
  each loop in turn — the usual convention for a nine played twice. A club that
  prescribes something else can edit it on the TD console;
* **par** doubles; **rating** doubles (the 18-hole rating of the same nine twice
  is the sum of the two); **slope** is unchanged.

Idempotent: asking again returns the same course and adds a doubled tee for any
source tee that has none yet (it does not follow later re-rates of the nine —
delete the doubled course on the console to rebuild it).
"""
from decimal import Decimal

from django.db import transaction

from core.models import Course, Tee


class NotANineHoleCourse(ValueError):
    """The course is not a nine-hole one, so there is nothing to double."""


def _current_tees(course):
    return list(course.tees.filter(superseded_by__isnull=True)
                .order_by('sort_priority', 'tee_name'))


def is_nine_hole(course) -> bool:
    tees = [t for t in _current_tees(course) if t.holes]
    return bool(tees) and max(len(t.holes) for t in tees) <= 9


def double_holes(holes: list) -> list:
    """Nine hole dicts → eighteen (see the module docstring)."""
    out = []
    for loop in (0, 1):
        for h in holes:
            d = dict(h)
            n = int(h['number'])
            d['number'] = n + 9 * loop
            si = h.get('stroke_index')
            if si is not None:
                d['stroke_index'] = 2 * int(si) - 1 + loop
            out.append(d)
    return out


def doubled_name(course) -> str:
    return f'{course.name} (played twice)'


@transaction.atomic
def get_or_create_doubled_course(course) -> Course:
    if course.doubled_of_id is not None:
        raise NotANineHoleCourse('That course is already a doubled one.')
    if not is_nine_hole(course):
        raise NotANineHoleCourse('Only a nine-hole course can be played twice.')

    doubled, _ = Course.objects.get_or_create(
        account=course.account, doubled_of=course,
        defaults=dict(
            name=doubled_name(course), city=course.city, state=course.state,
            country=course.country, latitude=course.latitude,
            longitude=course.longitude))

    have = {(t.tee_name, t.sex) for t in _current_tees(doubled)}
    for t in _current_tees(course):
        if not t.holes or (t.tee_name, t.sex) in have:
            continue
        Tee.objects.create(
            course=doubled, tee_name=t.tee_name, sex=t.sex,
            slope=t.slope,
            course_rating=(Decimal(t.course_rating) * 2).quantize(Decimal('0.1')),
            par=t.par * 2, holes=double_holes(t.holes),
            sort_priority=t.sort_priority,
            origin=Tee.ORIGIN_MANUAL, curated=True)
    return doubled
