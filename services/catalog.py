"""
services/catalog.py
-------------------
Shared course catalog (see core.models.CatalogCourse).

Two operations:
  * upsert_catalog_course(api_course, golf_api_id, name)
        Create/refresh the canonical CatalogCourse + CatalogTees from an adapted
        GolfCourseAPI course dict (deduped by golf_api_id).
  * clone_catalog_to_account(catalog_course, account)
        Copy a catalog course into an account's own Course/Tee rows
        ("copy-on-add").  Idempotent.  The clone is account-owned, so local
        edits — above all Tee.sort_priority — never touch the catalog or other
        accounts.
"""
from django.db import transaction


def _normalize_holes(holes):
    return [
        {
            'number'      : h['number'],
            'par'         : h['par'],
            'stroke_index': h['stroke_index'],
            'yards'       : h['yards'],
        }
        for h in holes
    ]


@transaction.atomic
def upsert_catalog_course(api_course: dict, golf_api_id, name: str):
    """Create or refresh the shared catalog entry for golf_api_id; return it."""
    from core.models import CatalogCourse, CatalogTee

    cc, _ = CatalogCourse.objects.update_or_create(
        golf_api_id=str(golf_api_id),
        defaults={
            'name'     : name,
            'city'     : api_course.get('city', '') or '',
            'state'    : api_course.get('state', '') or '',
            'country'  : api_course.get('country', '') or '',
            'latitude' : api_course.get('latitude'),
            'longitude': api_course.get('longitude'),
        },
    )
    # Rebuild tees from the authoritative API data.
    cc.tees.all().delete()
    for priority, tee_data in enumerate(api_course.get('tees', []), start=10):
        CatalogTee.objects.create(
            catalog_course        = cc,
            tee_name              = tee_data['name'] or 'Default',
            slope                 = max(55, min(155, tee_data['slope'])),
            course_rating         = tee_data['course_rating'],
            par                   = tee_data['par'],
            sex                   = tee_data['sex'],
            default_sort_priority = priority,
            holes                 = _normalize_holes(tee_data.get('holes', [])),
        )
    return cc


@transaction.atomic
def catalog_from_course(course, *, overwrite: bool = False):
    """
    Create/refresh a CatalogCourse from an EXISTING account Course's *current*
    data — preserving any local modifications (tee edits, sort_priority, etc.).
    No GolfCourseAPI call.  Used by the seed_catalog_from_courses backfill.

    Keyed by the course's golf_api_id when present, else a synthetic
    `local-<course_pk>` (so hand-built/custom courses can be cataloged too).

    Returns (catalog_course, status) where status is 'created' | 'updated' |
    'skipped' (skipped = an entry for this key already exists and overwrite=False).
    """
    from core.models import CatalogCourse, CatalogTee

    key = course.golf_api_id or f'local-{course.pk}'
    existing = CatalogCourse.objects.filter(golf_api_id=key).first()
    if existing is not None and not overwrite:
        return existing, 'skipped'

    cc, created = CatalogCourse.objects.update_or_create(
        golf_api_id=key,
        defaults={
            'name'     : course.name,
            'city'     : course.city,
            'state'    : course.state,
            'country'  : course.country,
            'latitude' : course.latitude,
            'longitude': course.longitude,
        },
    )
    cc.tees.all().delete()
    for t in course.tees.all():
        CatalogTee.objects.create(
            catalog_course        = cc,
            tee_name              = t.tee_name,
            slope                 = t.slope,
            course_rating         = t.course_rating,
            par                   = t.par,
            sex                   = t.sex,
            default_sort_priority = t.sort_priority,
            holes                 = t.holes,
        )
    return cc, ('created' if created else 'updated')


@transaction.atomic
def clone_catalog_to_account(catalog_course, account, *, replace_tees: bool = False):
    """
    Clone `catalog_course` into `account`'s own Course/Tee rows.

    Idempotent: if the account already has a Course with this golf_api_id,
    returns (course, created=False) and leaves it alone — unless `replace_tees`
    (a forced re-import), which refreshes the course fields and re-copies tees.

    Returns (course, created).
    """
    from core.models import Course, Tee

    course = Course.objects.filter(
        account=account, golf_api_id=catalog_course.golf_api_id,
    ).first()
    created = course is None

    if course is None:
        course = Course.objects.create(
            account=account, name=catalog_course.name,
            golf_api_id=catalog_course.golf_api_id,
            city=catalog_course.city, state=catalog_course.state,
            country=catalog_course.country,
            latitude=catalog_course.latitude, longitude=catalog_course.longitude,
        )
    elif replace_tees:
        course.name = catalog_course.name
        course.city = catalog_course.city
        course.state = catalog_course.state
        course.country = catalog_course.country
        course.latitude = catalog_course.latitude
        course.longitude = catalog_course.longitude
        course.save(update_fields=[
            'name', 'city', 'state', 'country', 'latitude', 'longitude',
        ])

    if created or replace_tees:
        if not created:
            course.tees.all().delete()  # may raise ProtectedError if tees are in use
        for ct in catalog_course.tees.all():
            Tee.objects.create(
                course=course, tee_name=ct.tee_name, slope=ct.slope,
                course_rating=ct.course_rating, par=ct.par, sex=ct.sex,
                sort_priority=ct.default_sort_priority, holes=ct.holes,
            )
    return course, created
