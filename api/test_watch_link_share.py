"""Sharing the watch link with a GROUP.

Paul, 11 Oct 2026: "Can I just jump to my text with the watch link... that
would allow me to send to a mix of halved users and non-halved users."

`inviteWatcher` is the right tool for one named spectator — it records the
Watcher row and texts that person. This is the other shape: hand the link to
the share sheet, pick an existing group thread, send to everybody at once.

Nobody is recorded, and nobody needs to be. A Halved recipient is filed as a
watcher by `WatchTokenResolveView` the moment they open it; anyone else reads
the web page, which is possession-gated and consults no Watcher row at all.
"""
from datetime import date
from decimal import Decimal

from django.test import TestCase, override_settings
from django.urls import reverse
from rest_framework.test import APIClient

from accounts.models import Account, User
from core.models import Course, Tee
from tournament.models import Round, Tournament, Watcher

HOLES = [{'number': n, 'par': 4, 'stroke_index': n} for n in range(1, 19)]


@override_settings(PUBLIC_BASE_URL='https://link.halved.golf')
class WatchLinkShareTests(TestCase):
    def setUp(self):
        self.acct = Account.objects.create(name="Paul's Golf")
        self.user = User.objects.create_user(username='paul', account=self.acct)
        self.user.phone = '+13105550100'
        self.user.save(update_fields=['phone'])
        self.client = APIClient()
        self.client.force_authenticate(self.user)

        course = Course.objects.create(account=self.acct, name='Tilden Park')
        Tee.objects.create(course=course, tee_name='White', slope=113,
                           course_rating=Decimal('72.0'), par=72, holes=HOLES)
        self.tourn = Tournament.objects.create(
            account=self.acct, name='Tester', start_date=date(2026, 6, 1),
            total_rounds=1, active_games=['low_net'])
        self.round = Round.objects.create(
            account=self.acct, course=course, tournament=self.tourn,
            round_number=1, status='in_progress', active_games=['skins'])
        self.casual = Round.objects.create(
            account=self.acct, course=course, round_number=1,
            status='in_progress', active_games=['skins'])

    def _round_link(self, r=None):
        return self.client.get(
            reverse('api-round-watch-link', args=[(r or self.round).id]))

    # -- the URL -----------------------------------------------------------

    def test_the_link_is_the_UNIVERSAL_link_host(self):
        """**The whole point.** Only `link.halved.golf` carries the iOS
        Associated Domains entitlement — a URL built off the API host opens
        Safari and never the app, which is what the leaderboard's "Copy round
        link" does. Harmless there (it is pasted into another round and only
        the token is read); it would be the entire bug here.
        """
        d = self._round_link().data
        self.assertTrue(d['watch_url'].startswith('https://link.halved.golf/'),
                        d['watch_url'])
        self.assertIn(self.round.watch_token, d['watch_url'])

    def test_a_tournament_links_its_in_progress_round(self):
        """Watch tokens live on Round, so a tournament has to pick one."""
        d = self.client.get(
            reverse('api-tournament-watch-link', args=[self.tourn.id])).data
        self.assertIn(self.round.watch_token, d['watch_url'])

    # -- the sentence ------------------------------------------------------

    def test_the_text_ends_with_the_link_on_its_own_line(self):
        """Last and alone, so every messaging client previews it."""
        text = self._round_link().data['share_text']
        self.assertTrue(text.endswith(self._round_link().data['watch_url']))
        self.assertIn('\n', text)

    def test_a_tournament_is_named_by_its_own_name(self):
        text = self.client.get(
            reverse('api-tournament-watch-link', args=[self.tourn.id])
        ).data['share_text']
        self.assertIn('Tester', text)

    def test_a_casual_round_is_named_by_game_and_course(self):
        text = self._round_link(self.casual).data['share_text']
        self.assertIn('Tilden Park', text)
        self.assertIn('Skins', text)

    def test_no_raw_slug_ever_reaches_the_message(self):
        """`public_game_name` returns '' for a slug it does not know —
        better to say nothing than print `low_net_round` at somebody."""
        self.casual.active_games = ['not_a_real_game']
        self.casual.save(update_fields=['active_games'])
        text = self._round_link(self.casual).data['share_text']
        self.assertNotIn('not_a_real_game', text)
        self.assertIn('Tilden Park', text)

    # -- what it does NOT do ------------------------------------------------

    def test_it_records_nobody(self):
        """A share is not an invite. The resolve files a Halved recipient
        when they open it; everyone else reads a possession-gated page."""
        self._round_link()
        self.assertFalse(Watcher.objects.exists())

    def test_a_stranger_cannot_read_it(self):
        other = Account.objects.create(name='Someone Else')
        nosy = User.objects.create_user(username='nosy', account=other)
        c = APIClient()
        c.force_authenticate(nosy)
        r = c.get(reverse('api-round-watch-link', args=[self.round.id]))
        self.assertEqual(r.status_code, 404)
