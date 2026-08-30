"""
api/test_merge_duplicate_golfers.py
-----------------------------------
The golfer-merge command (core/management/commands/merge_duplicate_golfers.py).

The tests that matter are the refusals: this command deletes a Player row, and
the only thing standing between it and a destroyed scorecard is the check that
the delete side holds no history.  So the mis-ordered pair, the cross-account
pair and the all-or-nothing batch each get a test.
"""

from decimal import Decimal
from io import StringIO

from django.core.management import call_command
from django.core.management.base import CommandError
from django.test import TestCase

from accounts.models import Account
from core.models import Course, Player, Tee
from tournament.models import Foursome, FoursomeMembership, Round


def _holes():
    return [{'number': n, 'par': 4, 'stroke_index': n, 'yards': 380}
            for n in range(1, 19)]


class MergeDuplicateGolfersTests(TestCase):
    def setUp(self):
        self.account = Account.objects.create(name='Tilden')

        # The original: has played, and has no phone — which is exactly why the
        # importer could not match them.
        self.keep = Player.objects.create(
            account=self.account, name='Wendel Doman',
            handicap_index=Decimal('16.1'))
        # The duplicate the import created: contact details, no history.
        self.drop = Player.objects.create(
            account=self.account, name='Wendell Doman',
            phone='+14155156761', email='w@x.com', ghin='12645554',
            handicap_index=Decimal('15.9'))

        course = Course.objects.create(account=self.account, name='Tilden Park')
        tee = Tee.objects.create(course=course, tee_name='White', slope=113,
                                 course_rating=Decimal('69.4'), par=72,
                                 holes=_holes())
        rnd = Round.objects.create(account=self.account, course=course)
        fs = Foursome.objects.create(round=rnd, group_number=1)
        FoursomeMembership.objects.create(
            foursome=fs, player=self.keep, tee=tee,
            course_handicap=16, playing_handicap=16)

    def _run(self, **kwargs):
        out = StringIO()
        call_command('merge_duplicate_golfers', stdout=out, **kwargs)
        return out.getvalue()

    # -- the happy path -----------------------------------------------------

    def test_dry_run_writes_nothing(self):
        out = self._run(pairs=f'{self.keep.id}:{self.drop.id}')
        self.assertIn('DRY RUN', out)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.phone, '')
        self.assertTrue(Player.objects.filter(pk=self.drop.pk).exists())

    def test_apply_moves_contact_details_and_deletes_the_duplicate(self):
        self._run(pairs=f'{self.keep.id}:{self.drop.id}', apply=True)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.phone, '+14155156761')
        self.assertEqual(self.keep.email, 'w@x.com')
        self.assertEqual(self.keep.ghin, '12645554')
        # The imported index is the current WHS value, so it wins by default.
        self.assertEqual(self.keep.handicap_index, Decimal('15.9'))
        self.assertFalse(Player.objects.filter(pk=self.drop.pk).exists())
        # ...and the history is untouched.
        self.assertEqual(self.keep.memberships.count(), 1)

    def test_keep_index_leaves_the_handicap_alone(self):
        self._run(pairs=f'{self.keep.id}:{self.drop.id}', apply=True,
                  keep_index=True)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.handicap_index, Decimal('16.1'))
        self.assertEqual(self.keep.phone, '+14155156761')   # contact still moved

    def test_rename_takes_the_duplicates_spelling(self):
        self._run(pairs=f'{self.keep.id}:{self.drop.id}', apply=True, rename=True)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.name, 'Wendell Doman')

    def test_name_is_not_changed_without_rename(self):
        self._run(pairs=f'{self.keep.id}:{self.drop.id}', apply=True)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.name, 'Wendel Doman')

    # -- the refusals -------------------------------------------------------

    def test_reversed_pair_is_refused_and_names_the_fix(self):
        """The whole safety of this command is that it won't delete history."""
        with self.assertRaises(CommandError) as ctx:
            self._run(pairs=f'{self.drop.id}:{self.keep.id}', apply=True)
        self.assertIn('holds history', str(ctx.exception))
        self.assertIn(f'--pairs {self.keep.id}:{self.drop.id}', str(ctx.exception))
        self.assertTrue(Player.objects.filter(pk=self.keep.pk).exists())

    def test_cross_account_merge_is_refused(self):
        other = Account.objects.create(name='Somebody Else')
        stranger = Player.objects.create(
            account=other, name='Wendell Doman', phone='+15105550000',
            handicap_index=Decimal('15.9'))
        with self.assertRaises(CommandError) as ctx:
            self._run(pairs=f'{self.keep.id}:{stranger.id}', apply=True)
        self.assertIn('across accounts', str(ctx.exception))

    def test_a_bad_pair_rolls_back_the_whole_batch(self):
        """All-or-nothing: half a merged roster is worse than none."""
        good_keep = Player.objects.create(
            account=self.account, name='Will Glennon',
            handicap_index=Decimal('15.8'))
        good_drop = Player.objects.create(
            account=self.account, name='Will Glennon', phone='+15107179418',
            handicap_index=Decimal('15.8'))

        with self.assertRaises(CommandError):
            self._run(pairs=f'{good_keep.id}:{good_drop.id},'
                            f'{self.drop.id}:{self.keep.id}',   # reversed
                      apply=True)
        # The good pair must NOT have been applied.
        good_keep.refresh_from_db()
        self.assertEqual(good_keep.phone, '')
        self.assertTrue(Player.objects.filter(pk=good_drop.pk).exists())

    def test_unknown_id_is_refused(self):
        with self.assertRaises(CommandError) as ctx:
            self._run(pairs=f'{self.keep.id}:999999', apply=True)
        self.assertIn('No golfer with id 999999', str(ctx.exception))

    def test_malformed_pairs_are_refused(self):
        for bad in ('238', '238:abc', ''):
            with self.assertRaises(CommandError):
                self._run(pairs=bad)

    def test_self_merge_is_refused(self):
        with self.assertRaises(CommandError) as ctx:
            self._run(pairs=f'{self.keep.id}:{self.keep.id}', apply=True)
        self.assertIn('into themselves', str(ctx.exception))

    def test_a_blank_on_the_duplicate_never_clears_a_real_value(self):
        self.keep.email = 'already@known.com'
        self.keep.save()
        self.drop.email = ''
        self.drop.save()
        self._run(pairs=f'{self.keep.id}:{self.drop.id}', apply=True)
        self.keep.refresh_from_db()
        self.assertEqual(self.keep.email, 'already@known.com')
