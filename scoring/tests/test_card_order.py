"""A side's golfers read in CARD order, in every game that has sides.

`Team.players` is a many-to-many with NO ordering, so the database returns a
side's golfers in whatever order it likes — `Sam + Mike` on one request and
`Mike + Sam` on the next, from the same rows. That is the name of a SIDE,
reordering under the reader on the board, the score-entry tray, the side
headers and the money rows.

**It has been found four times**: the Sixes anchor took its anchor from set
iteration, then `nassau_summary`, `fourball_summary` and
`sixes_summary`/`vegas_summary`/`cup_standings` all shipped it. Twice it was
caught only by accident — a fixture regenerating differently against
unchanged code, and a test failing under `--parallel 4` with
`TypeError: cannot pickle 'traceback' object`, which names nothing.

So this covers the family rather than one game, and **every fixture forces
membership order and pk order apart**: a test whose two orderings agree
cannot pin which one is read, which is exactly how the Sixes anchor test
passed against its own bug.
"""
from django.test import TestCase
from tournament.models import FoursomeMembership

from ._helpers import make_foursome, make_round, make_tee, submit_hole


class _SidesBase(TestCase):
    """Paul, Dave | Sam, Mike — with Paul's membership recreated so his
    membership id is the HIGHEST while his player pk stays the lowest."""

    NAMES = [('Paul Kelly', 0), ('Dave Moran', 0),
             ('Sam Reid', 0), ('Lee Naylor', 0)]

    def setUp(self):
        self.tee   = make_tee()
        self.round = make_round(self.tee.course, handicap_mode='gross')
        self.fs    = make_foursome(self.round, self.NAMES, tee=self.tee)
        self.pid = {m.player.name.split()[0]: m.player_id
                    for m in self.fs.memberships.select_related('player')}
        m = self.fs.memberships.get(player_id=self.pid['Paul'])
        tee, ch, ph = m.tee, m.course_handicap, m.playing_handicap
        m.delete()
        FoursomeMembership.objects.create(
            foursome=self.fs, player_id=self.pid['Paul'],
            tee=tee, course_handicap=ch, playing_handicap=ph)
        self.assertLess(self.pid['Paul'], self.pid['Dave'],
                        'the fixture only means something while the pks run '
                        'the other way')

    @property
    def card(self):
        """The names in card order — Paul last, because of the setUp."""
        return [m.player.name for m in
                self.fs.memberships.select_related('player')]

    def assert_in_card_order(self, names):
        rank = {n: i for i, n in enumerate(self.card)}
        got  = [rank[n] for n in names]
        self.assertEqual(got, sorted(got),
                         f'{names} is not the order they sit on the card')


class TheRuleItselfTests(TestCase):

    def test_an_unknown_golfer_sorts_LAST(self):
        """A stray id must not silently take the top of a side."""
        from services.player_labels import in_card_order

        class P:
            def __init__(self, i):
                self.id = i
        got = in_card_order([P(9), P(1), P(2)], {1: 0, 2: 1})
        self.assertEqual([p.id for p in got], [1, 2, 9])

    def test_the_rank_is_membership_order(self):
        from services.player_labels import card_order
        tee = make_tee()
        rnd = make_round(tee.course)
        fs  = make_foursome(rnd, [('A A', 0), ('B B', 0)], tee=tee)
        ranks = card_order(fs)
        ids = [m.player_id for m in fs.memberships.all()]
        self.assertEqual([ranks[i] for i in ids], [0, 1])


class NassauSidesTests(_SidesBase):

    def test_a_side_reads_in_card_order(self):
        from services.nassau import nassau_summary, setup_nassau
        setup_nassau(self.fs, [self.pid['Paul'], self.pid['Dave']],
                     [self.pid['Sam'], self.pid['Lee']],
                     handicap_mode='gross')
        teams = nassau_summary(self.fs)['teams']
        self.assert_in_card_order([p['name'] for p in teams['team1']])


class FourballSidesTests(_SidesBase):

    def test_a_side_reads_in_card_order(self):
        from services.fourball import fourball_summary, setup_fourball
        setup_fourball(self.fs, [self.pid['Paul'], self.pid['Dave']],
                       [self.pid['Sam'], self.pid['Lee']],
                       handicap_mode='gross')
        s = fourball_summary(self.fs)
        self.assert_in_card_order(s['team1']['players'])


class VegasSidesTests(_SidesBase):

    def test_a_side_reads_in_card_order(self):
        from services.vegas import setup_vegas, vegas_summary
        setup_vegas(self.fs, [self.pid['Paul'], self.pid['Dave']],
                    [self.pid['Sam'], self.pid['Lee']],
                    handicap_mode='gross')
        teams = vegas_summary(self.fs)['teams']
        self.assert_in_card_order(
            [p['name'] for p in teams[0]['players']])


class SixesSidesTests(_SidesBase):

    def test_a_side_reads_in_card_order(self):
        self._setup()
        from services.sixes import sixes_summary
        seg = sixes_summary(self.fs)['segments'][0]
        self.assert_in_card_order(seg['team1']['players'])

    def _setup(self):
        from services.sixes import setup_sixes
        base = {
            'team_select_method': 'long_drive',
            'team1_player_ids': [self.pid['Paul'], self.pid['Dave']],
            'team2_player_ids': [self.pid['Sam'], self.pid['Lee']],
        }
        setup_sixes(self.fs, [
            {**base, 'start_hole': 1,  'end_hole': 6},
            {**base, 'start_hole': 7,  'end_hole': 12},
            {**base, 'start_hole': 13, 'end_hole': 18},
        ], handicap_mode='gross')

    def test_and_the_same_on_every_read(self):
        """The bug was not a wrong order — it was an unstable one."""
        self._setup()
        from services.sixes import sixes_summary
        first = sixes_summary(self.fs)['segments'][0]['team1']['players']
        for _ in range(4):
            self.assertEqual(
                sixes_summary(self.fs)['segments'][0]['team1']['players'],
                first)


class EveryGameWithSidesIsCoveredTests(TestCase):
    """A fifth game fails HERE rather than shipping it a fifth time.

    Reads the source for `team.players.all()` with no ordering on it, in the
    services that build a side's NAME list — the only place the order
    reaches a reader. An id set, a membership test or a sum over nets does
    not care, which is why this names the files rather than banning the call.
    """

    FILES = ['services/nassau.py', 'services/fourball.py',
             'services/vegas.py', 'services/sixes.py',
             'services/cup_standings.py', 'services/ryder_cup.py',
             'services/triple_cup.py', 'services/cup_singles.py',
             'services/cup_change_game.py', 'api/views.py']

    #: How far past an unordered read to look for a name. Both shapes that
    #: actually shipped are inside this: the one-liner
    #: `[p.name for p in t.players.all()]`, and the two-step
    #: `players = t.players.all()` followed by `[p.name for p in players]`.
    WINDOW = 6

    def test_none_of_them_builds_a_name_list_off_the_raw_relation(self):
        """**A heuristic, and it says so.** It cannot prove the general
        case — a name taken twenty lines later, or through a second
        variable, walks past it. What it does catch is the two shapes this
        bug has actually taken four times, which is the point of a guard
        written after the fourth."""
        import pathlib, re
        root = pathlib.Path(__file__).resolve().parents[2]
        bad = []
        for f in self.FILES:
            lines = (root / f).read_text().split('\n')
            for i, line in enumerate(lines):
                if 'players.all()' not in line:
                    continue
                if 'in_card_order' in line or 'sorted(' in line:
                    continue
                # **Both directions.** A comprehension reads bottom-up in
                # source — `[{'name': p.name, ...} for p in t.players.all()]`
                # puts the name ABOVE the unordered read, which a
                # forward-only window walks straight past. It did.
                window = '\n'.join(
                    lines[max(0, i - self.WINDOW):i + self.WINDOW])
                # A site may opt out by SAYING WHY on the line above, which
                # is the point of making the exemption a sentence rather
                # than a cleverer regex: the reader order has to be argued,
                # not assumed.
                above = '\n'.join(lines[max(0, i - 3):i])
                if 'card-order-safe:' in above:
                    continue
                if re.search(r'\b\w+\.(name|short_name)\b', window):
                    bad.append(f'{f}:{i + 1}  {line.strip()}')
        self.assertEqual(bad, [], 'these read a side\'s NAMES off an '
                                  'unordered many-to-many — use '
                                  'player_labels.in_card_order')
