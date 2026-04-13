/// screens/player_form_screen.dart
/// Add a new player or edit an existing one.
/// Returns true to the caller if a save was made.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../providers/auth_provider.dart';
import '../widgets/error_view.dart';

class PlayerFormScreen extends StatefulWidget {
  /// Pass null to create a new player, or a PlayerProfile to edit.
  final PlayerProfile? player;

  const PlayerFormScreen({super.key, this.player});

  @override
  State<PlayerFormScreen> createState() => _PlayerFormScreenState();
}

class _PlayerFormScreenState extends State<PlayerFormScreen> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _nameCtrl;
  late final TextEditingController _hcpCtrl;
  late final TextEditingController _emailCtrl;
  late final TextEditingController _phoneCtrl;

  bool    _saving = false;
  String? _error;

  bool get _isEdit => widget.player != null;

  @override
  void initState() {
    super.initState();
    final p = widget.player;
    _nameCtrl  = TextEditingController(text: p?.name ?? '');
    _hcpCtrl   = TextEditingController(text: p?.handicapIndex ?? '');
    _emailCtrl = TextEditingController(text: p?.email ?? '');
    _phoneCtrl = TextEditingController(text: p?.phone ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _hcpCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() { _saving = true; _error = null; });

    try {
      final client = context.read<AuthProvider>().client;
      final name  = _nameCtrl.text.trim();
      final hcp   = _hcpCtrl.text.trim();
      final email = _emailCtrl.text.trim();
      final phone = _phoneCtrl.text.trim();

      if (_isEdit) {
        await client.updatePlayer(
          widget.player!.id,
          name: name,
          handicapIndex: hcp,
          email: email,
          phone: phone,
        );
      } else {
        await client.createPlayer(
          name: name,
          handicapIndex: hcp,
          email: email,
          phone: phone,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() { _error = friendlyError(e); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? 'Edit Player' : 'Add Player'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ---- Name ----
              TextFormField(
                controller: _nameCtrl,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Full Name',
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Name is required';
                  if (v.trim().length < 2) return 'Name too short';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Handicap Index ----
              TextFormField(
                controller: _hcpCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(
                  labelText: 'Handicap Index',
                  hintText: 'e.g. 14.2',
                  prefixIcon: Icon(Icons.golf_course),
                  border: OutlineInputBorder(),
                  helperText: 'WHS index between -10.0 and 54.0',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Handicap is required';
                  final d = double.tryParse(v.trim());
                  if (d == null) return 'Enter a valid number';
                  if (d < -10 || d > 54) return 'Must be between -10 and 54';
                  return null;
                },
              ),

              const SizedBox(height: 16),

              // ---- Email ----
              TextFormField(
                controller: _emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email (optional)',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null; // optional
                  final ok = RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(v.trim());
                  return ok ? null : 'Enter a valid email';
                },
              ),

              const SizedBox(height: 16),

              // ---- Phone ----
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: 'Phone (optional)',
                  prefixIcon: Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(),
                ),
              ),

              const SizedBox(height: 28),

              // ---- Error ----
              if (_error != null) ...[
                ErrorView(message: _error!),
                const SizedBox(height: 16),
              ],

              // ---- Save ----
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check),
                label: Text(_saving
                    ? 'Saving…'
                    : _isEdit ? 'Save Changes' : 'Add Player'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
