/// utils/primary_handicap.dart
/// ---------------------------
/// Side games never carry their own handicap configuration — the PRIMARY game
/// drives Strokes-Off / Net% / Gross for the whole round. This resolves the
/// primary's (mode, net%) so a side game's setup can inherit it instead of
/// presenting its own selector.

import '../api/client.dart';
import '../api/models.dart';
import '../game_catalog.dart';

/// Resolve the primary game's handicap (mode, net%) for [round] / [foursomeId].
/// Best-effort: on any failure (or an unconfigured primary) it falls back to
/// the round-level handicap. Only the casual primaries that allow side games
/// are handled; the rest can't have side games anyway.
Future<(String mode, int netPercent)> primaryHandicapFor(
  ApiClient client,
  Round round,
  int foursomeId,
) async {
  final primary = resolvePrimary(round.primaryGame, round.activeGames);
  try {
    switch (primary) {
      case 'fourball':
        final s = await client.getFourballSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'points_531':
        final s = await client.getPoints531Summary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'wolf':
        final s = await client.getWolfSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'rabbit':
        final s = await client.getRabbitSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'match_play':
        final m = await client.getMatchPlay(foursomeId);
        final h = m['handicap'] as Map?;
        if (h != null) {
          return (h['mode'] as String? ?? 'net',
                  h['net_percent'] as int? ?? 100);
        }
        break;
      case 'skins':
        final s = await client.getSkinsSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'stableford':
        final c = await client.getStablefordConfig(round.id);
        return (c['handicap_mode'] as String? ?? 'net',
                c['net_percent'] as int? ?? 100);
      case 'nassau':
        final s = await client.getNassauSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'sixes':
        final s = await client.getSixesSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'vegas':
        final s = await client.getVegasSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'triple_cup':
        final s = await client.getTripleCupSummary(foursomeId);
        return (s.handicapMode, s.netPercent);
      case 'low_net_round':
      case 'low_net':
        final c = await client.getLowNetConfig(round.id);
        return (c['handicap_mode'] as String? ?? 'net',
                c['net_percent'] as int? ?? 100);
      case 'quota_nassau':
        return ('gross', 100);   // Quota Nassau is gross-only
    }
  } catch (_) {/* fall through to round default */}
  return (round.handicapMode, round.netPercent);
}
