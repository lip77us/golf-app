"""Backfill the catalog-propagation scope onto existing data.

Two jobs, both derived purely from current data (no API calls):

1. Classify every account Tee as catalog-origin vs. deliberate local variant.
   An account Tee is matched to its course's CatalogCourse (by the course's
   golf_api_id) on (tee_name, sex):
     * MATCH  -> origin='api',    curated=False  (USGA re-rates will flow in)
     * NO MATCH (incl. hand-pasted courses with no golf_api_id, and extra tees
       like a re-rated "White-Sixes") -> origin='manual', curated=True  (the
       lazy catalog sync will skip these forever)

2. Stamp each account Course.catalog_synced_version to its CatalogCourse's
   current data_version, so already-cloned courses start "up to date" and the
   lazy sync only fires from the NEXT upstream re-import onward (no day-one mass
   re-sync that could clobber pre-existing local divergence).

Reverse is a no-op — the schema migration drops the columns.
"""
from django.db import migrations


def backfill(apps, schema_editor):
    Course = apps.get_model('core', 'Course')
    CatalogCourse = apps.get_model('core', 'CatalogCourse')

    # Per catalog course: the set of (name, sex) keys and the current version.
    catalog_keys = {}
    catalog_versions = {}
    for cc in CatalogCourse.objects.prefetch_related('tees').all():
        catalog_keys[cc.golf_api_id] = {
            (t.tee_name.casefold(), t.sex) for t in cc.tees.all()
        }
        catalog_versions[cc.golf_api_id] = cc.data_version

    for course in Course.objects.prefetch_related('tees').all():
        keys = catalog_keys.get(course.golf_api_id) if course.golf_api_id else None
        for tee in course.tees.all():
            in_catalog = keys is not None and (tee.tee_name.casefold(), tee.sex) in keys
            tee.origin = 'api' if in_catalog else 'manual'
            tee.curated = not in_catalog
            tee.save(update_fields=['origin', 'curated'])

        version = catalog_versions.get(course.golf_api_id) if course.golf_api_id else None
        if version is not None:
            course.catalog_synced_version = version
            course.save(update_fields=['catalog_synced_version'])


class Migration(migrations.Migration):

    dependencies = [
        ('core', '0013_catalogcourse_data_version_and_more'),
    ]

    operations = [
        migrations.RunPython(backfill, migrations.RunPython.noop),
    ]
