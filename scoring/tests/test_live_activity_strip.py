"""
scoring/tests/test_live_activity_strip.py
-----------------------------------------
The four-across strip — the set's answer to any four-name card.

Four stacked rows of place / name / score / thru measured **201pt** against the
160 ceiling, which is clipped on device. The same four figures per golfer cost
**62pt** across. Wolf established the shape; the Stableford foursome and the
Stroke Play flight proved it retroactively
(`~/Downloads/handoff-lock-screens 2/shared/HEIGHT-AUDIT.md`, finding 3).

Three cards share it, so it is assembled in one place — a column built three
ways is three vocabularies for one row — and these tests pin the shape that
contract rests on.
"""
from django.test import TestCase

from services.live_activity_registry import strip_column, surname


class SurnameTests(TestCase):

    def test_it_takes_the_last_word_in_caps(self):
        """A column is about sixty points and a first name spends it on
        nothing."""
        self.assertEqual(surname('Dave Moran'), 'MORAN')
        self.assertEqual(surname('paul lipkin'), 'LIPKIN')

    def test_a_single_word_is_already_a_surname(self):
        self.assertEqual(surname('Reid'), 'REID')

    def test_it_survives_the_empty_and_the_untrimmed(self):
        self.assertEqual(surname('  Sam   Reid  '), 'REID')
        self.assertEqual(surname(''), '')
        self.assertEqual(surname(None), '')


class ColumnTests(TestCase):

    def test_the_label_is_sent_even_when_empty(self):
        """The columns are read ACROSS. One starting a row higher than its
        neighbours makes the figures stop lining up, so the slot is always
        spent."""
        self.assertEqual(strip_column(name='Reid', figure='12')['label'], '')

    def test_the_optional_keys_are_omitted_rather_than_sent_empty(self):
        """Swift decodes them as `String?`, and an empty string would draw an
        empty row of its own."""
        col = strip_column(name='Reid', figure='12')
        self.assertNotIn('note', col)
        self.assertNotIn('rule', col)

    def test_a_qualifier_rides_under_the_figure(self):
        col = strip_column(name='Reid', figure='+3', note='thru 11')
        self.assertEqual(col['note'], 'thru 11')

    def test_the_side_rule_is_carried_as_a_colour_name(self):
        """Blue is the wolf's side, orange the field — a 2px rule rather than a
        coloured name, since a name at 62% white in orange is unreadable at a
        nit and colouring the figure would collide with mint."""
        self.assertEqual(
            strip_column(name='Moran', figure='8', rule='blue')['rule'], 'blue')

    def test_unclaimed_carries_no_rule_at_all(self):
        """Grey is the honest state before a call — three of these men are
        about to be on a side and none of them knows which."""
        self.assertNotIn('rule', strip_column(name='Moran', figure='8'))

    def test_reader_and_leader_are_separate_facts(self):
        """The reader can be behind and the leader can be somebody else; a
        column marks each independently."""
        col = strip_column(name='Reid', figure='12',
                           is_reader=True, is_leader=False)
        self.assertTrue(col['is_reader'])
        self.assertFalse(col['is_leader'])


class ContractTests(TestCase):
    """Every key the Swift decodes has to be one this emits, and vice versa."""

    SWIFT = ('mobile/ios/SixesActivity/SixesActivity.swift')

    def _swift(self):
        import pathlib
        return pathlib.Path(self.SWIFT).read_text()

    # Swift spells two of these in camelCase and maps them back with a
    # CodingKey, so the check is per key rather than one loop with an
    # exception in it.
    _PLAIN     = ('label', 'name', 'figure', 'note', 'rule')
    _MAPPED    = {'is_reader': 'isReader', 'is_leader': 'isLeader'}

    def test_every_key_the_column_emits_exists_in_StripCol(self):
        swift = self._swift()
        col = strip_column(name='Reid', figure='12', label='WOLF',
                           note='thru 11', rule='blue',
                           is_reader=True, is_leader=True)
        self.assertEqual(set(col),
                         set(self._PLAIN) | set(self._MAPPED),
                         'a column key was added or removed')
        for key in self._PLAIN:
            self.assertIn(f'{key}: String', swift,
                          f'`{key}` has no field in StripCol')
        for snake, camel in self._MAPPED.items():
            self.assertIn(f'case {camel} = "{snake}"', swift,
                          f'`{snake}` has no CodingKey in StripCol')

    def test_the_strip_slot_exists_on_the_state(self):
        self.assertIn('var strip: [StripCol]? = nil', self._swift())
