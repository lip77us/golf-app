/// screens/login_screen.dart
/// Phone-first sign-in (freemium design §12): the user enters their cell
/// number, we send an SMS one-time passcode, and they verify it on the next
/// screen.  A new number self-creates an account.  The legacy
/// account/username/password form is still reachable via the link at the
/// bottom ([PasswordLoginScreen] at /login-password).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  final _formKey   = GlobalKey<FormState>();
  final _phoneCtrl = TextEditingController();
  final _nameCtrl  = TextEditingController();

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _nameCtrl.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    final auth  = context.read<AuthProvider>();
    final phone = _phoneCtrl.text.trim();
    final name  = _nameCtrl.text.trim();

    final debugCode = await auth.requestOtp(phone);
    if (!mounted) return;
    if (auth.error == null) {
      Navigator.of(context).pushNamed('/verify-otp', arguments: {
        'phone': phone,
        'name':  name,
        'debugCode': debugCode,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<AuthProvider>();
    final theme = Theme.of(context);

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
                  Icon(Icons.golf_course,
                      size: 72, color: theme.colorScheme.primary),
                  const SizedBox(height: 8),
                  Text('Halved',
                      style: theme.textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    'Sign in with your phone number',
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: theme.colorScheme.outline),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),

                  // Phone number
                  GolfTextField(
                    controller: _phoneCtrl,
                    label: 'Phone number',
                    hint: '(555) 555-1234',
                    prefixIcon: Icons.phone_outlined,
                    keyboardType: TextInputType.phone,
                    textInputAction: TextInputAction.next,
                    autocorrect: false,
                    inputFormatters: [
                      // Allow digits, spaces, and common phone punctuation;
                      // the server normalizes to E.164.
                      FilteringTextInputFormatter.allow(
                          RegExp(r'[0-9+()\-\s]')),
                    ],
                    validator: (v) {
                      final digits =
                          (v ?? '').replaceAll(RegExp(r'[^0-9]'), '');
                      return digits.length < 10
                          ? 'Enter a valid phone number'
                          : null;
                    },
                  ),
                  const SizedBox(height: 16),

                  // Optional name (seeds a new account on first sign-in)
                  GolfTextField(
                    controller: _nameCtrl,
                    label: 'Your name (new accounts)',
                    helper: 'Used only if this number is signing up for the '
                            'first time',
                    prefixIcon: Icons.badge_outlined,
                    textInputAction: TextInputAction.done,
                    onFieldSubmitted: (_) => _sendCode(),
                  ),
                  const SizedBox(height: 8),

                  if (auth.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        auth.error!,
                        style: TextStyle(color: theme.colorScheme.error),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  const SizedBox(height: 24),

                  GolfPrimaryButton(
                    label: 'Send code',
                    loading: auth.loading,
                    onPressed: _sendCode,
                    height: 48,
                  ),
                  const SizedBox(height: 16),

                  TextButton(
                    onPressed: () =>
                        Navigator.of(context).pushNamed('/login-password'),
                    child: const Text('Sign in with a username instead'),
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
