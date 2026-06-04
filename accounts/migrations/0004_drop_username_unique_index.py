"""
Drop any single-column UNIQUE *index* on accounts_user.username left over
from earlier setups.

Companion to 0003_drop_username_unique.  That migration removed single-
column UNIQUE *constraints* (pg_constraint, contype='u'), but a global
UNIQUE created as a plain index — e.g. ``CREATE UNIQUE INDEX
accounts_user_username_key ON accounts_user (username)`` — lives only in
pg_index, not pg_constraint, so 0003 walked right past it.  On a
production DB that originated from the phase-1 raw-SQL bootstrap, that
stray unique index is what still blocks the same username from existing
in two accounts ("can't add a 'gary' to account B because account A
already has one").

This migration finds any single-column unique, non-primary index on
accounts_user whose column is `username` and drops it.  The intended
composite index ``(lower(username), account_id)`` is a TWO-column index
so it is never matched, and the non-unique ``username_like`` pattern
index is skipped because it isn't unique.

Idempotent: the DO block simply finds nothing on an already-clean DB
(such as one built fresh from migrations).
"""

from django.db import migrations


SQL = r"""
DO $$
DECLARE
    iname text;
BEGIN
    FOR iname IN
        SELECT i.relname
        FROM   pg_index     ix
        JOIN   pg_class     i ON i.oid = ix.indexrelid
        JOIN   pg_class     t ON t.oid = ix.indrelid
        JOIN   pg_attribute a ON a.attrelid = t.oid
                             AND a.attnum   = ANY(ix.indkey)
        WHERE  t.relname    = 'accounts_user'
          AND  ix.indisunique
          AND  NOT ix.indisprimary
          AND  ix.indnatts  = 1          -- single-column only
          AND  a.attname    = 'username'
    LOOP
        EXECUTE format('DROP INDEX IF EXISTS %I', iname);
        RAISE NOTICE 'Dropped single-column UNIQUE index on '
                     'accounts_user.username: %', iname;
    END LOOP;
END $$;
"""


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0003_drop_username_unique'),
    ]

    operations = [
        migrations.RunSQL(
            sql=SQL,
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]
