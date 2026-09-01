"""
Push the Sixes lock screen to whoever has one registered for a round.

The point of this command is that you can exercise the whole delivery path —
provider token, topic, payload shape, Swift decoding — without playing golf.
A key mismatch between the Python dict and Swift's CodingKeys is otherwise
silent: Apple accepts the push, the phone discards it, and the lock screen
just never moves.

    python manage.py push_activity 42
    python manage.py push_activity 42 --final
    python manage.py push_activity 42 --show     # print, send nothing
    python manage.py push_activity 42 --start    # RAISE a card on the phones
                                                 # that have not got one
"""
from django.core.management.base import BaseCommand, CommandError

from services import live_activity_push
from tournament.models import LiveActivityToken, Round


class Command(BaseCommand):
    help = 'Push the current Sixes lock-screen state for a round.'

    def add_arguments(self, parser):
        parser.add_argument('round_id', type=int)
        parser.add_argument('--final', action='store_true',
                            help='Send the closing frame and clear the tokens.')
        parser.add_argument('--show', action='store_true',
                            help='Print the state; send nothing.')
        parser.add_argument(
            '--start', action='store_true',
            help='Push-to-start: raise a card on every recipient who has a '
                 'start token and is not already running one. This is the '
                 'path that puts the board on the NON-scoring golfers.')

    def handle(self, *args, **opts):
        try:
            rnd = Round.objects.get(pk=opts['round_id'])
        except Round.DoesNotExist:
            raise CommandError(f'No round {opts["round_id"]}.')

        if opts['start']:
            return self._start(rnd)

        rows = LiveActivityToken.objects.filter(round=rnd)
        self.stdout.write(f'Round {rnd.id} — {rows.count()} activity token(s) '
                          f'registered.')
        if not rows:
            self.stdout.write(self.style.WARNING(
                'Nothing to push.  A phone registers when it posts the first '
                'score of a Sixes round.'))
            return

        backend = live_activity_push._backend()
        if backend == 'apns' and not live_activity_push.is_configured():
            raise CommandError(
                'LIVE_ACTIVITY_BACKEND=apns but the key is incomplete — need '
                'APNS_KEY_PATH (or APNS_KEY_P8), APNS_KEY_ID and APNS_TEAM_ID.')

        if opts['show']:
            self._show(rnd, opts['final'])
            return

        self.stdout.write(f'Backend: {backend}'
                          + ('  [SANDBOX]'
                             if live_activity_push._host().endswith(
                                 'sandbox.push.apple.com') else ''))
        sent = live_activity_push.push_round(rnd, final=opts['final'])
        style = self.style.SUCCESS if sent else self.style.WARNING
        self.stdout.write(style(f'Accepted by Apple: {sent}/{rows.count()}'))

    def _start(self, rnd):
        """Exercise the push-to-start path without a second golfer.

        Prints WHY nobody would get one, which is the whole difficulty in
        testing this: a start push that reaches nobody looks identical to one
        that was never sent.
        """
        from services.live_activity_registry import (board_recipients,
                                                     round_has_board)
        from tournament.models import LiveActivityStartToken

        if not round_has_board(rnd):
            raise CommandError(
                f'Round {rnd.id} has no lock-screen board — its primary game '
                f'is not one of the games with a builder.')

        recipients = board_recipients(rnd)
        running = set(LiveActivityToken.objects
                      .filter(round=rnd, user_id__in=recipients)
                      .values_list('user_id', flat=True))
        absent = recipients - running
        holders = set(LiveActivityStartToken.objects
                      .filter(user_id__in=absent)
                      .values_list('user_id', flat=True))

        self.stdout.write(f'Round {rnd.id}')
        self.stdout.write(f'  recipients (players + watchers): {len(recipients)}')
        self.stdout.write(f'  already running a card:          {len(running)}')
        self.stdout.write(f'  absent, holding a start token:   {len(holders)}')
        if not holders:
            self.stdout.write(self.style.WARNING(
                'Nobody to start. A phone posts a start token on sign-in, and '
                'only on iOS 17.2+ with Live Activities enabled.'))
            return

        backend = live_activity_push._backend()
        self.stdout.write(f'Backend: {backend}'
                          + ('  [SANDBOX]'
                             if live_activity_push._host().endswith(
                                 'sandbox.push.apple.com') else ''))
        sent = live_activity_push.push_start_to_absent(rnd)
        style = self.style.SUCCESS if sent else self.style.WARNING
        self.stdout.write(style(f'Accepted by Apple: {sent}/{len(holders)}'))

    def _show(self, rnd, final):
        import json

        from services.live_activity_registry import activity_state

        for row in LiveActivityToken.objects.filter(round=rnd):
            state = activity_state(rnd, row.user, final=final)
            self.stdout.write(f'\n— {row.user} —')
            self.stdout.write(json.dumps(state, indent=2) if state
                              else '(nothing to show)')
