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

    def handle(self, *args, **opts):
        try:
            rnd = Round.objects.get(pk=opts['round_id'])
        except Round.DoesNotExist:
            raise CommandError(f'No round {opts["round_id"]}.')

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

    def _show(self, rnd, final):
        import json

        from api.views import _holes_played, _sixes_foursome_for
        from services.live_activity import (sixes_activity_state,
                                            sixes_final_state)

        for row in LiveActivityToken.objects.filter(round=rnd):
            foursome, player_id = _sixes_foursome_for(rnd, row.user)
            if foursome is None:
                continue
            state = (sixes_final_state(foursome, player_id=player_id) if final
                     else sixes_activity_state(foursome, player_id=player_id,
                                               thru=_holes_played(foursome)))
            self.stdout.write(f'\n— {row.user} —')
            self.stdout.write(json.dumps(state, indent=2))
