import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/golf_text_field.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey      = GlobalKey<FormState>();
  final _accountCtrl  = TextEditingController();
  final _userCtrl     = TextEditingController();
  final _passCtrl     = TextEditingController();
  bool  _obscure      = true;
  bool  _prefilled    = false;

  @override
  void dispose() {
    _accountCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    await auth.login(
      _accountCtrl.text.trim(),
      _userCtrl.text.trim(),
      _passCtrl.text,
    );
    if (auth.isLoggedIn && mounted) {
      Navigator.of(context).pushReplacementNamed('/tournaments');
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    // Pre-fill the account name on first build after the provider
    // restored its session — saves the user from retyping their
    // (typically stable) group name every launch.
    if (!_prefilled && auth.lastAccountName != null) {
      _accountCtrl.text = auth.lastAccountName!;
      _prefilled = true;
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Logo / title
                  Icon(Icons.golf_course,
                      size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 8),
                  Text('Golf App',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 40),

                  // Account name
                  GolfTextField(
                    controller: _accountCtrl,
                    label: 'Account',
                    helper: 'Your club / group / family name',
                    prefixIcon: Icons.groups_outlined,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),

                  // Username
                  GolfTextField(
                    controller: _userCtrl,
                    label: 'Username',
                    prefixIcon: Icons.person_outline,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    validator: (v) =>
                        (v == null || v.trim().isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 16),

                  // Password
                  GolfTextField(
                    controller: _passCtrl,
                    obscureText: _obscure,
                    label: 'Password',
                    prefixIcon: Icons.lock_outline,
                    suffix: IconButton(
                      icon: Icon(_obscure
                          ? Icons.visibility_off
                          : Icons.visibility),
                      onPressed: () =>
                          setState(() => _obscure = !_obscure),
                    ),
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _submit(),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                  const SizedBox(height: 8),

                  // Error message
                  if (auth.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        auth.error!,
                        style: TextStyle(
                            color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 24),

                  // Login button
                  GolfPrimaryButton(
                    label: 'Sign In',
                    loading: auth.loading,
                    onPressed: _submit,
                    height: 48,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
