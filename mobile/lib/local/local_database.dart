/// local/local_database.dart
///
/// SQLite wrapper for offline-first score storage.
///
/// Two responsibilities:
///   1. PENDING QUEUE — stores score submissions that haven't reached the
///      server yet (written on every "Save Hole", deleted after a successful
///      API response).
///   2. CACHE — stores the last-known-good server state for rounds and
///      scorecards so the app can display meaningful data without a connection.
///
/// Usage
///   final db = LocalDatabase();
///   await db.init();           // call once at app start
///   await db.enqueuScore(…);   // called by RoundProvider
///   await db.pendingScores(…); // called by SyncService

import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// One score-submission that is waiting to reach the server.
class PendingScore {
  final int    id;
  final int    foursomeId;
  final int    holeNumber;
  /// Raw list of {player_id, gross_score} maps.
  final List<Map<String, int>> scores;
  final bool   pinkBallLost;
  final DateTime createdAt;
  final int    retryCount;

  const PendingScore({
    required this.id,
    required this.foursomeId,
    required this.holeNumber,
    required this.scores,
    required this.pinkBallLost,
    required this.createdAt,
    required this.retryCount,
  });

  factory PendingScore.fromRow(Map<String, dynamic> row) {
    final rawScores = jsonDecode(row['scores_json'] as String) as List;
    return PendingScore(
      id:           row['id']           as int,
      foursomeId:   row['foursome_id']  as int,
      holeNumber:   row['hole_number']  as int,
      scores:       rawScores
                      .cast<Map<String, dynamic>>()
                      .map((s) => {
                            'player_id':   s['player_id']   as int,
                            'gross_score': s['gross_score'] as int,
                          })
                      .toList(),
      pinkBallLost: (row['pink_ball_lost'] as int) == 1,
      createdAt:    DateTime.parse(row['created_at'] as String),
      retryCount:   row['retry_count'] as int,
    );
  }
}

class LocalDatabase {
  static const _dbName    = 'golf_app.db';
  static const _dbVersion = 1;

  Database? _db;

  Future<Database> get _database async {
    _db ??= await _open();
    return _db!;
  }

  // ── Open / migrate ────────────────────────────────────────────────────────

  Future<void> init() async {
    _db = await _open();
  }

  Future<Database> _open() async {
    final dbPath = join(await getDatabasesPath(), _dbName);
    return openDatabase(
      dbPath,
      version: _dbVersion,
      onCreate: _create,
    );
  }

  Future<void> _create(Database db, int version) async {
    // Scores that have been saved locally but not yet confirmed by the server.
    await db.execute('''
      CREATE TABLE pending_scores (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        foursome_id    INTEGER NOT NULL,
        hole_number    INTEGER NOT NULL,
        scores_json    TEXT    NOT NULL,
        pink_ball_lost INTEGER NOT NULL DEFAULT 0,
        created_at     TEXT    NOT NULL,
        retry_count    INTEGER NOT NULL DEFAULT 0
      )
    ''');

    // Last-known-good scorecard JSON per foursome.
    await db.execute('''
      CREATE TABLE cached_scorecards (
        foursome_id INTEGER PRIMARY KEY,
        data_json   TEXT    NOT NULL,
        cached_at   TEXT    NOT NULL
      )
    ''');

    // Last-known-good round JSON per round.
    await db.execute('''
      CREATE TABLE cached_rounds (
        round_id  INTEGER PRIMARY KEY,
        data_json TEXT    NOT NULL,
        cached_at TEXT    NOT NULL
      )
    ''');
  }

  // ── Pending queue — writes ────────────────────────────────────────────────

  /// Save a hole submission to the local queue.
  /// Returns the row ID (used internally; callers can ignore it).
  Future<int> enqueueScore({
    required int foursomeId,
    required int holeNumber,
    required List<Map<String, int>> scores,
    bool pinkBallLost = false,
  }) async {
    final db = await _database;
    return db.insert('pending_scores', {
      'foursome_id':    foursomeId,
      'hole_number':    holeNumber,
      'scores_json':    jsonEncode(scores),
      'pink_ball_lost': pinkBallLost ? 1 : 0,
      'created_at':     DateTime.now().toIso8601String(),
      'retry_count':    0,
    });
  }

  /// Mark a submission as successfully synced — remove it from the queue.
  Future<void> deletePending(int id) async {
    final db = await _database;
    await db.delete('pending_scores', where: 'id = ?', whereArgs: [id]);
  }

  /// Increment retry counter for a pending submission (called on transient failure).
  Future<void> incrementRetry(int id) async {
    final db = await _database;
    await db.rawUpdate(
      'UPDATE pending_scores SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  // ── Pending queue — reads ─────────────────────────────────────────────────

  /// All pending submissions, oldest first.
  Future<List<PendingScore>> allPending() async {
    final db   = await _database;
    final rows = await db.query(
      'pending_scores',
      orderBy: 'created_at ASC',
    );
    return rows.map(PendingScore.fromRow).toList();
  }

  /// Pending submissions for a specific foursome, keyed by hole number.
  /// Used to overlay local scores on top of the server scorecard in the UI.
  /// Returns {holeNumber: {playerId: grossScore}}.
  Future<Map<int, Map<int, int>>> pendingForFoursome(int foursomeId) async {
    final db   = await _database;
    final rows = await db.query(
      'pending_scores',
      where:     'foursome_id = ?',
      whereArgs: [foursomeId],
    );

    final result = <int, Map<int, int>>{};
    for (final row in rows.map(PendingScore.fromRow)) {
      final byPlayer = <int, int>{};
      for (final s in row.scores) {
        byPlayer[s['player_id']!] = s['gross_score']!;
      }
      // If multiple pending rows for the same hole, the latest wins.
      result[row.holeNumber] = byPlayer;
    }
    return result;
  }

  /// Total number of unsynced submissions.
  Future<int> pendingCount() async {
    final db     = await _database;
    final result = await db.rawQuery(
      'SELECT COUNT(*) AS cnt FROM pending_scores',
    );
    return result.first['cnt'] as int? ?? 0;
  }

  // ── Scorecard cache ───────────────────────────────────────────────────────

  Future<void> cacheScorecard(int foursomeId, Map<String, dynamic> json) async {
    final db = await _database;
    await db.insert(
      'cached_scorecards',
      {
        'foursome_id': foursomeId,
        'data_json':   jsonEncode(json),
        'cached_at':   DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getCachedScorecard(int foursomeId) async {
    final db   = await _database;
    final rows = await db.query(
      'cached_scorecards',
      where:     'foursome_id = ?',
      whereArgs: [foursomeId],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['data_json'] as String)
        as Map<String, dynamic>;
  }

  // ── Round cache ───────────────────────────────────────────────────────────

  Future<void> cacheRound(int roundId, Map<String, dynamic> json) async {
    final db = await _database;
    await db.insert(
      'cached_rounds',
      {
        'round_id':  roundId,
        'data_json': jsonEncode(json),
        'cached_at': DateTime.now().toIso8601String(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<Map<String, dynamic>?> getCachedRound(int roundId) async {
    final db   = await _database;
    final rows = await db.query(
      'cached_rounds',
      where:     'round_id = ?',
      whereArgs: [roundId],
    );
    if (rows.isEmpty) return null;
    return jsonDecode(rows.first['data_json'] as String) as Map<String, dynamic>;
  }

  // ── Housekeeping ──────────────────────────────────────────────────────────

  /// Wipe everything — used during sign-out so a different user
  /// doesn't see someone else's cached data.
  Future<void> clearAll() async {
    final db = await _database;
    await db.delete('pending_scores');
    await db.delete('cached_scorecards');
    await db.delete('cached_rounds');
  }
}
