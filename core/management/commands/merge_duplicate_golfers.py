"""
management command: merge_duplicate_golfers
-------------------------------------------
Fold a duplicate golfer record into the one that owns the golf.

Why this exists: the Golf Genius importer matches on **normalized phone, then
GHIN**.  A golfer already on the roster with NEITHER cannot be matched by any
means — the importer has nothing to match on — so the file's row correctly
becomes a new golfer.  The result is two rows for one person: the original,
carrying every round they have played, and the new one, carrying the phone,
email and GHIN that would have let them be matched.

Neither row can simply be dropped:

* The **original is PROTECTed** — ``FoursomeMembership`` and ``HoleScore`` (and
  the per-game result tables) all reference ``Player`` with ``on_delete=PROTECT``,
  so deleting it would raise ``ProtectedError``.  Rightly: that history belongs
  to other golfers' scorecards too.
* Deleting the **new** one alone throws away the contact details, and the next
  import would recreate it, because the original still has no phone.

So the fix is a merge in one direction only: **contact details move onto the
record with the history, and the empty duplicate is deleted.**  Phone is the
identity key across accounts, so putting it on the row that owns the rounds is
also what makes "On Halved", shared rounds and every future import line up.

Pairs are given EXPLICITLY.  Name matching is deliberately not automated —
the real data had ``Wendel``/``Wendell`` and ``Rico Young``/``Richard (Rico)
Young`` (which exact matching misses) alongside ``Roger Bird``/``Francis Bird``
(which surname matching would wrongly fuse).  A human reads the list; this
command only executes it.

Dry-run by DEFAULT, like the importer.  ``--apply`` commits.

Usage
-----
    python manage.py merge_duplicate_golfers --pairs 238:428,260:390
    python manage.py merge_duplicate_golfers --pairs 238:428 --apply

``--pairs`` is ``keep:delete`` — the id that KEEPS the history first.  Order
matters and is checked: the delete side must have no history at all, and the
command refuses the whole batch rather than half-applying a bad one.
"""

from django.core.management.base import BaseCommand, CommandError
from django.db import transaction

from core.models import Player


# Fields that move from the duplicate onto the keeper.  `handicap_index` is
# here because the imported value is the CURRENT one from Golf Genius — taking
# it is exactly what the importer would have written had it matched on phone.
# `--keep-index` opts out.
CONTACT_FIELDS = ('phone', 'email', 'ghin')

# JSON fields that store player ids as plain numbers (or as dict keys).  An FK
# sweep cannot see these, and a missed one leaves a round pointing at a golfer
# who no longer exists.  Matched by NAME across every model, because each name
# here means "player ids" wherever it appears.
PLAYER_ID_JSON_FIELDS = {
    'participant_player_ids', 'excluded_player_ids', 'player_order',
    'wolf_order', 'pink_ball_order', 'drive_pairs', 'drives_used',
}


def _swap_ids(value, old, new):
    """`value` with every occurrence of player id `old` replaced by `new` —
    list items, nested pairs, and dict keys (JSON keys are strings)."""
    if isinstance(value, list):
        return [_swap_ids(v, old, new) for v in value]
    if isinstance(value, dict):
        return {(str(new) if k == str(old) else k): _swap_ids(v, old, new)
                for k, v in value.items()}
    if isinstance(value, int) and not isinstance(value, bool) and value == old:
        return new
    if isinstance(value, str) and value == str(old):
        return str(new)
    return value


def _player_references():
    """Every (model, field, kind) that points at Player: FK, M2M or JSON."""
    from django.apps import apps
    from django.db.models import JSONField
    refs = []
    for model in apps.get_models():
        for f in model._meta.get_fields():
            if f.auto_created and not f.concrete:
                continue
            if getattr(f, 'related_model', None) is Player:
                if f.many_to_many:
                    refs.append((model, f.name, 'm2m'))
                elif f.many_to_one or f.one_to_one:
                    refs.append((model, f.name, 'fk'))
            elif isinstance(f, JSONField) and f.name in PLAYER_ID_JSON_FIELDS:
                refs.append((model, f.name, 'json'))
    return refs


def _json_hits(model, field, pid):
    """Rows of `model` whose JSON `field` mentions `pid` anywhere."""
    hits = []
    for obj in model.objects.exclude(**{f'{field}__isnull': True}).only('pk', field):
        val = getattr(obj, field)
        if _swap_ids(val, pid, -1) != val:
            hits.append(obj)
    return hits


class Command(BaseCommand):
    help = ('Merge an import-created duplicate golfer into the record that '
            'holds their rounds, then delete the duplicate.')

    def add_arguments(self, parser):
        parser.add_argument(
            '--pairs', required=True,
            help='Comma-separated keep:delete player-id pairs, e.g. '
                 '"238:428,260:390". The KEEP id is the one with the rounds.')
        parser.add_argument(
            '--rename', action='store_true',
            help="Also take the duplicate's spelling of the name (e.g. "
                 "'Wendel Doman' -> 'Wendell Doman').")
        parser.add_argument(
            '--keep-index', action='store_true',
            help='Leave the keeper\'s handicap index alone. Default is to take '
                 'the imported one, which is the current WHS value.')
        parser.add_argument(
            '--repoint', action='store_true',
            help='For a duplicate that has ALREADY BEEN PLAYED WITH: move every '
                 'round, score and game row it holds onto the keeper first, '
                 'then delete it. Refused if the two ever shared a group.')
        parser.add_argument(
            '--apply', action='store_true',
            help='Commit. Without it this is a dry run and writes nothing.')

    def handle(self, *args, **opts):
        pairs = self._parse_pairs(opts['pairs'])
        plan = [self._plan_one(keep_id, drop_id, opts)
                for keep_id, drop_id in pairs]

        for row in plan:
            self._print(row)

        if not opts['apply']:
            self.stdout.write(self.style.WARNING(
                f'\nDRY RUN — nothing written. {len(plan)} merge'
                f'{"" if len(plan) == 1 else "s"} ready; re-run with --apply '
                f'to commit.'))
            return

        # One transaction for the batch: a bad pair should not leave the roster
        # half-merged, with some golfers' contact details moved and others not.
        with transaction.atomic():
            for row in plan:
                self._commit(row, opts)

        self.stdout.write(self.style.SUCCESS(
            f'\nDone: {len(plan)} golfer{"" if len(plan) == 1 else "s"} merged, '
            f'{len(plan)} duplicate{"" if len(plan) == 1 else "s"} deleted.'))

    # -- planning -----------------------------------------------------------

    def _parse_pairs(self, raw):
        pairs = []
        for chunk in (raw or '').split(','):
            chunk = chunk.strip()
            if not chunk:
                continue
            if ':' not in chunk:
                raise CommandError(
                    f'"{chunk}" is not a keep:delete pair — expected e.g. 238:428.')
            keep, drop = chunk.split(':', 1)
            try:
                pairs.append((int(keep), int(drop)))
            except ValueError:
                raise CommandError(f'"{chunk}" must be two integer player ids.')
        if not pairs:
            raise CommandError('No pairs given.')
        return pairs

    def _plan_one(self, keep_id, drop_id, opts):
        if keep_id == drop_id:
            raise CommandError(f'{keep_id}: a golfer cannot be merged into themselves.')

        keep = self._get(keep_id)
        drop = self._get(drop_id)

        # Same tenant, always.  Merging across accounts would move one group's
        # golfer into another's roster.
        if keep.account_id != drop.account_id:
            raise CommandError(
                f'{keep_id} is in account {keep.account_id} and {drop_id} is in '
                f'{drop.account_id} — refusing to merge across accounts.')

        # The delete side must be empty.  This is the check that makes the
        # command safe to run on a mis-ordered pair: it refuses rather than
        # destroying the history.
        history = self._history(drop)
        repoint = {}
        if history and not opts.get('repoint'):
            raise CommandError(
                f'{drop_id} ({drop.name}) has {history} — it holds history and '
                f'cannot be deleted. Did you mean --pairs {drop_id}:{keep_id}? '
                f'If both really are the same golfer and both have played, '
                f'--repoint moves the history across first.')
        if opts.get('repoint'):
            # Two golfers who played in the SAME group cannot be one golfer:
            # both would own a score on the same hole of the same card.  That
            # needs a person, not a script.
            shared = (set(keep.memberships.values_list('foursome_id', flat=True))
                      & set(drop.memberships.values_list('foursome_id', flat=True)))
            if shared:
                raise CommandError(
                    f'{keep_id} and {drop_id} both played in foursome(s) '
                    f'{sorted(shared)} — they cannot be the same golfer. Refusing.')
            repoint = self._repoint_plan(drop)

        changes = {}
        for field in CONTACT_FIELDS:
            new = (getattr(drop, field) or '').strip()
            have = (getattr(keep, field) or '').strip()
            # Never clear a value the keeper already has with a blank.
            if not new or new == have:
                continue
            # And never REPLACE a phone the keeper already has.  The phone is
            # what links a roster golfer to his login, and a duplicate made by
            # an import usually carries whatever number the source file had —
            # a landline, an old cell.  Copying it over a keeper who already
            # has the right one silently unlinks him from his own account.
            if field == 'phone' and have:
                continue
            changes[field] = new
        if not opts['keep_index'] and drop.handicap_index is not None \
                and drop.handicap_index != keep.handicap_index:
            changes['handicap_index'] = drop.handicap_index
        if opts['rename'] and drop.name and drop.name != keep.name:
            changes['name'] = drop.name

        return {'keep': keep, 'drop': drop, 'changes': changes,
                'kept_history': self._history(keep), 'repoint': repoint}

    def _repoint_plan(self, drop):
        """{label: count} of every row that points at `drop`."""
        plan = {}
        for model, field, kind in _player_references():
            label = f'{model._meta.label}.{field}'
            if kind == 'fk':
                n = model.objects.filter(**{field: drop}).count()
            elif kind == 'm2m':
                n = model.objects.filter(**{field: drop}).count()
            else:
                n = len(_json_hits(model, field, drop.id))
            if n:
                plan[label] = n
        return plan

    def _do_repoint(self, keep, drop):
        from core.models import FavoriteGolfer
        for model, field, kind in _player_references():
            if kind == 'fk':
                qs = model.objects.filter(**{field: drop})
                if model is FavoriteGolfer:
                    # One flag per owner: if he already flagged the keeper, the
                    # duplicate's flag is simply dropped.
                    for fav in qs:
                        if FavoriteGolfer.objects.filter(
                                owner=fav.owner, player=keep).exists():
                            fav.delete()
                        else:
                            fav.player = keep
                            fav.save(update_fields=['player'])
                    continue
                qs.update(**{field: keep})
            elif kind == 'm2m':
                for obj in model.objects.filter(**{field: drop}):
                    rel = getattr(obj, field)
                    rel.remove(drop)
                    rel.add(keep)
            else:
                for obj in _json_hits(model, field, drop.id):
                    setattr(obj, field, _swap_ids(getattr(obj, field),
                                                  drop.id, keep.id))
                    obj.save(update_fields=[field])

    def _get(self, pk) -> Player:
        try:
            return Player.objects.get(pk=pk)
        except Player.DoesNotExist:
            raise CommandError(f'No golfer with id {pk}.')

    def _history(self, player) -> str:
        """A human description of what this golfer is holding, or '' if empty."""
        rounds = player.memberships.count()
        scores = player.hole_scores.count()
        parts = []
        if rounds:
            parts.append(f'{rounds} round{"" if rounds == 1 else "s"}')
        if scores:
            parts.append(f'{scores} hole score{"" if scores == 1 else "s"}')
        return ' and '.join(parts)

    # -- output / commit ----------------------------------------------------

    def _print(self, row):
        keep, drop, changes = row['keep'], row['drop'], row['changes']
        self.stdout.write(self.style.MIGRATE_HEADING(
            f'\n{keep.name}  (keep #{keep.id}, delete #{drop.id})'))
        self.stdout.write(f'  keeps {row["kept_history"] or "no history"}')
        if not changes:
            self.stdout.write('  nothing to copy — already identical')
        for field, value in changes.items():
            before = getattr(keep, field)
            before = before if before not in (None, '') else '—'
            self.stdout.write(f'  {field:<15} {before}  →  {value}')
        if row.get('repoint'):
            self.stdout.write(f'  moves onto #{keep.id}:')
            for label, n in sorted(row['repoint'].items()):
                self.stdout.write(f'    {n:>4}  {label}')
        self.stdout.write(f'  then delete #{drop.id} ({drop.name})')

    def _commit(self, row, opts):
        keep, drop, changes = row['keep'], row['drop'], row['changes']
        if opts.get('repoint'):
            self._do_repoint(keep, drop)
            drop.refresh_from_db()
        if changes:
            for field, value in changes.items():
                setattr(keep, field, value)
            keep.save()
        # Re-check under the transaction: a round could have been posted against
        # the duplicate between the plan and the commit.
        if self._history(drop):
            raise CommandError(
                f'{drop.id} gained history while this ran — nothing committed.')
        drop.delete()
