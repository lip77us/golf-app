"""
Drop any single-column UNIQUE constraint on accounts_user.username
left over from earlier setups.

Background: phase 1's `swap_to_accounts` command created the
accounts_user table via raw SQL that included `username varchar(150)
NOT NULL UNIQUE`.  When phase 3's 0002 migration removed
`unique=True` from the username field, Django's schema editor didn't
explicitly drop the column-level UNIQUE — it only dropped a `_like`
index — so production ended up with a global UNIQUE on username
even though Django's model says it isn't unique anymore.  That
broke the "same username in two accounts" invariant: adding a
"gary" to a second account collided with the gary in Golden Glove.

This migration finds any single-column UNIQUE constraint on
accounts_user.username and drops it.  Multi-column UNIQUE
constraints (our intended `(LOWER(username), account_id)` index)
are untouched because they reference more than one column.

Idempotent on a clean DB — the DO block returns immediately if no
matching constraint exists.
"""

from django.db import migrations


SQL = r"""
DO $$
DECLARE
    cname text;
BEGIN
    FOR cname IN
        SELECT c.conname
        FROM   pg_constraint c
        JOIN   pg_class     t ON t.oid = c.conrelid
        JOIN   pg_attribute a ON a.attrelid = t.oid
                             AND a.attnum  = ANY(c.conkey)
        WHERE  c.contype     = 'u'
          AND  t.relname     = 'accounts_user'
          AND  a.attname     = 'username'
          AND  array_length(c.conkey, 1) = 1
    LOOP
        EXECUTE format(
            'ALTER TABLE accounts_user DROP CONSTRAINT %I',
            cname
        );
        RAISE NOTICE 'Dropped single-column UNIQUE on '
                     'accounts_user.username: %', cname;
    END LOOP;
END $$;
"""


class Migration(migrations.Migration):

    dependencies = [
        ('accounts', '0002_username_per_account'),
    ]

    operations = [
        migrations.RunSQL(
            sql=SQL,
            reverse_sql=migrations.RunSQL.noop,
        ),
    ]
