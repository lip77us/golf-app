/// screens/manage_members_screen.dart
/// -----------------------------------
/// Account-admin member management.
///
/// Shows the roster of users inside the caller's Account, with quick
/// actions to add a new member, promote/demote between admin/regular,
/// reset passwords, and remove members.  Admin-only — entry point is
/// gated by AuthProvider.isAccountAdmin in app_drawer.dart.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../providers/auth_provider.dart';

class ManageMembersScreen extends StatefulWidget {
  const ManageMembersScreen({super.key});

  @override
  State<ManageMembersScreen> createState() => _ManageMembersScreenState();
}

class _ManageMembersScreenState extends State<ManageMembersScreen> {
  bool          _loading  = true;
  String?       _error;
  List<Member>  _members  = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final list   = await client.getAccountMembers();
      list.sort((a, b) {
        // Admins first, then alphabetical.
        if (a.isAccountAdmin != b.isAccountAdmin) {
          return a.isAccountAdmin ? -1 : 1;
        }
        return a.username.toLowerCase().compareTo(b.username.toLowerCase());
      });
      if (mounted) setState(() { _members = list; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _openAddDialog() async {
    final added = await showDialog<Member>(
      context: context,
      builder: (_) => const _AddMemberDialog(),
    );
    if (added != null) await _load();
  }

  Future<void> _openMemberSheet(Member m) async {
    final changed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _MemberActionsSheet(member: m),
    );
    if (changed == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final auth    = context.watch<AuthProvider>();
    final account = auth.account?.name ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Manage Members'),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openAddDialog,
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Add Member'),
      ),
      body: _buildBody(account),
    );
  }

  Widget _buildBody(String account) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.red)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ]),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 96),
        itemCount: _members.length + 1,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (ctx, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: Text(
                account.isEmpty
                    ? 'Members of this account'
                    : 'Members of $account',
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                    color: Theme.of(ctx).colorScheme.onSurfaceVariant),
              ),
            );
          }
          final m = _members[i - 1];
          return _MemberTile(member: m, onTap: () => _openMemberSheet(m));
        },
      ),
    );
  }
}

// ── Member row ──────────────────────────────────────────────────────────────

class _MemberTile extends StatelessWidget {
  final Member        member;
  final VoidCallback  onTap;

  const _MemberTile({required this.member, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: member.isAccountAdmin
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        foregroundColor: member.isAccountAdmin
            ? theme.colorScheme.onPrimaryContainer
            : theme.colorScheme.onSurfaceVariant,
        child: Icon(member.isAccountAdmin
            ? Icons.shield_outlined
            : Icons.person_outline),
      ),
      title: Text(
        member.displayName,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '@${member.username}'
        '${member.email.isNotEmpty ? ' · ${member.email}' : ''}',
        style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant),
      ),
      trailing: member.isAccountAdmin
          ? Chip(
              label: const Text('Admin'),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              backgroundColor: theme.colorScheme.primaryContainer,
              labelStyle: TextStyle(
                color:    theme.colorScheme.onPrimaryContainer,
                fontSize: 12,
              ),
            )
          : const Icon(Icons.chevron_right),
    );
  }
}

// ── Add Member dialog ───────────────────────────────────────────────────────

class _AddMemberDialog extends StatefulWidget {
  const _AddMemberDialog();

  @override
  State<_AddMemberDialog> createState() => _AddMemberDialogState();
}

class _AddMemberDialogState extends State<_AddMemberDialog> {
  final _formKey      = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _emailCtrl    = TextEditingController();
  final _firstCtrl    = TextEditingController();
  final _lastCtrl     = TextEditingController();
  bool   _isAdmin     = false;
  bool   _saving      = false;
  String? _error;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _emailCtrl.dispose();
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() { _saving = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      final m = await client.createAccountMember(
        username:       _usernameCtrl.text.trim(),
        password:       _passwordCtrl.text,
        email:          _emailCtrl.text.trim(),
        firstName:      _firstCtrl.text.trim(),
        lastName:       _lastCtrl.text.trim(),
        isAccountAdmin: _isAdmin,
      );
      if (mounted) Navigator.of(context).pop(m);
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _saving = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _saving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Member'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _usernameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Username',
                  helperText: 'Unique within this account',
                ),
                autocorrect: false,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _passwordCtrl,
                decoration: const InputDecoration(
                  labelText: 'Initial password',
                  helperText: '≥ 8 characters.  Share with the user '
                              'out-of-band.',
                ),
                obscureText: true,
                validator: (v) {
                  if (v == null || v.isEmpty) return 'Required';
                  if (v.length < 8) return 'Must be at least 8 chars';
                  return null;
                },
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: TextFormField(
                  controller: _firstCtrl,
                  decoration: const InputDecoration(labelText: 'First name'),
                )),
                const SizedBox(width: 8),
                Expanded(child: TextFormField(
                  controller: _lastCtrl,
                  decoration: const InputDecoration(labelText: 'Last name'),
                )),
              ]),
              const SizedBox(height: 8),
              TextFormField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email (optional)'),
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Account admin'),
                subtitle: const Text('Can manage members + configure games'),
                contentPadding: EdgeInsets.zero,
                value: _isAdmin,
                onChanged: (v) => setState(() => _isAdmin = v),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18, height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add'),
        ),
      ],
    );
  }
}

// ── Member-actions bottom sheet ─────────────────────────────────────────────

class _MemberActionsSheet extends StatefulWidget {
  final Member member;
  const _MemberActionsSheet({required this.member});

  @override
  State<_MemberActionsSheet> createState() => _MemberActionsSheetState();
}

class _MemberActionsSheetState extends State<_MemberActionsSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _toggleAdmin() async {
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.updateAccountMember(
        widget.member.id,
        isAccountAdmin: !widget.member.isAccountAdmin,
      );
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  Future<void> _resetPassword() async {
    final pw = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordResetDialog(),
    );
    if (pw == null || pw.isEmpty) return;
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.updateAccountMember(widget.member.id, password: pw);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove member?'),
        content: Text(
          'Remove ${widget.member.displayName} from this account?  '
          'Their existing rounds stay, but they can no longer log in.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() { _busy = true; _error = null; });
    try {
      final client = context.read<AuthProvider>().client;
      await client.deleteAccountMember(widget.member.id);
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (mounted) setState(() { _error = e.message; _busy = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _busy = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;

    // We don't currently know the viewer's user.id on the mobile side
    // (auth tracks Player.id, not User.id), so the UI shows the
    // "Remove" button for everyone and relies on the API's
    // self-delete + last-admin guards to surface a clear 400 if the
    // viewer tries to remove themselves.

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(m.displayName,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text('@${m.username}'
                '${m.email.isNotEmpty ? '  ·  ${m.email}' : ''}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 16),

            if (_error != null) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.errorContainer,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer)),
              ),
              const SizedBox(height: 12),
            ],

            ListTile(
              leading: Icon(m.isAccountAdmin
                  ? Icons.remove_moderator_outlined
                  : Icons.add_moderator_outlined),
              title: Text(m.isAccountAdmin
                  ? 'Demote from admin'
                  : 'Promote to admin'),
              onTap: _busy ? null : _toggleAdmin,
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.password_outlined),
              title: const Text('Reset password'),
              onTap: _busy ? null : _resetPassword,
              contentPadding: EdgeInsets.zero,
            ),
            ListTile(
              leading: const Icon(Icons.person_remove_outlined,
                  color: Colors.red),
              title: const Text('Remove from account',
                  style: TextStyle(color: Colors.red)),
              onTap: _busy ? null : _delete,
              contentPadding: EdgeInsets.zero,
            ),

            if (_busy) const Padding(
              padding: EdgeInsets.only(top: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Password-reset prompt ──────────────────────────────────────────────────

class _PasswordResetDialog extends StatefulWidget {
  const _PasswordResetDialog();

  @override
  State<_PasswordResetDialog> createState() => _PasswordResetDialogState();
}

class _PasswordResetDialogState extends State<_PasswordResetDialog> {
  final _ctrl = TextEditingController();
  String? _err;

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('New password'),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(
          labelText: 'New password',
          helperText: '≥ 8 characters',
          errorText: _err,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final v = _ctrl.text;
            if (v.length < 8) {
              setState(() => _err = 'At least 8 characters');
              return;
            }
            Navigator.of(context).pop(v);
          },
          child: const Text('Set'),
        ),
      ],
    );
  }
}
