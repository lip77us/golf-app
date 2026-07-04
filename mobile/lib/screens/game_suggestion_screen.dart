/// screens/game_suggestion_screen.dart
/// ------------------------------------
/// "Suggest a Game" — a free-form note to the Halved team requesting a new
/// game, with prompts for the details we need to evaluate it (players, rounds,
/// per-hole scoring, betting). Submitted to the server and stored for review.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';
import '../widgets/golf_text_field.dart';

class GameSuggestionScreen extends StatefulWidget {
  const GameSuggestionScreen({super.key});

  @override
  State<GameSuggestionScreen> createState() => _GameSuggestionScreenState();
}

class _GameSuggestionScreenState extends State<GameSuggestionScreen> {
  final _name     = TextEditingController();
  final _players  = TextEditingController();
  final _rounds   = TextEditingController();
  final _scoring  = TextEditingController();
  final _betting  = TextEditingController();
  final _notes    = TextEditingController();
  final _email    = TextEditingController();

  bool    _saving = false;
  Object? _error;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  @override
  void initState() {
    super.initState();
    // Pre-fill with the golfer's profile email so it's one less thing to type
    // (still editable + required).
    final email = context.read<AuthProvider>().player?.email.trim() ?? '';
    if (email.isNotEmpty) _email.text = email;
  }

  @override
  void dispose() {
    for (final c in [_name, _players, _rounds, _scoring, _betting, _notes,
        _email]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Need at least one descriptive field — mirrors the server's guard so the
  /// Send button can't fire an empty note.
  bool get _hasContent =>
      _name.text.trim().isNotEmpty ||
      _scoring.text.trim().isNotEmpty ||
      _betting.text.trim().isNotEmpty ||
      _notes.text.trim().isNotEmpty;

  /// A valid email is required so we can follow up on the suggestion.
  bool get _emailValid => _emailRe.hasMatch(_email.text.trim());

  Future<void> _submit() async {
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.submitGameSuggestion(
        gameName:    _name.text.trim(),
        numPlayers:  _players.text.trim(),
        numRounds:   _rounds.text.trim(),
        holeScoring: _scoring.text.trim(),
        betting:     _betting.text.trim(),
        notes:       _notes.text.trim(),
        contactEmail: _email.text.trim(),
      );
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.check_circle_outline),
          title: const Text('Thank you!'),
          content: const Text(
            'Thanks for suggesting a game — we review every idea.\n\n'
            'Want to add details or follow up? Email us anytime at '
            'info@halved.golf.',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(); // close the form
    } catch (e) {
      if (mounted) setState(() { _error = e; _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Suggest a Game')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Have a game we should add?',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Tell us about it — the more detail the better. Number of '
              'players, number of rounds, how each hole is scored, and how the '
              'betting works are the most helpful.',
              style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),

            GolfTextField(
              controller: _name,
              label: 'Game name',
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: GolfTextField(
                  controller: _players,
                  label: 'Number of players',
                  keyboardType: TextInputType.text,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: GolfTextField(
                  controller: _rounds,
                  label: 'Number of rounds',
                  keyboardType: TextInputType.text,
                ),
              ),
            ]),
            const SizedBox(height: 12),
            GolfTextField(
              controller: _scoring,
              label: 'How each hole is scored',
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            GolfTextField(
              controller: _betting,
              label: 'How the betting works',
              minLines: 2,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            GolfTextField(
              controller: _notes,
              label: 'Anything else',
              minLines: 2,
              maxLines: 6,
              textCapitalization: TextCapitalization.sentences,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            GolfTextField(
              controller: _email,
              label: 'Your email (required, for follow-up)',
              keyboardType: TextInputType.emailAddress,
              onChanged: (_) => setState(() {}),
              errorText: (_email.text.trim().isNotEmpty && !_emailValid)
                  ? 'Enter a valid email address'
                  : null,
            ),

            if (_error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(friendlyError(_error!),
                    style: TextStyle(color: theme.colorScheme.onErrorContainer)),
              ),
            ],

            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: (_saving || !_hasContent || !_emailValid)
                  ? null : _submit,
              icon: _saving
                  ? const SizedBox(
                      width: 18, height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.send_outlined),
              label: Text(_saving ? 'Sending…' : 'Send Suggestion'),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}
