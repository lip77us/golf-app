/// screens/otp_verify_screen.dart
/// Step 2 of phone-first sign-in: enter the 6-digit SMS code.  On success an
/// existing number lands on the tournaments list; a brand-new number (which
/// just self-created an account) is routed through profile setup first.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../widgets/golf_primary_button.dart';
import '../widgets/golf_text_field.dart';

class OtpVerifyScreen extends StatefulWidget {
  final String phone;
  final String? name;
  /// Dev-only code echoed by the server under DEBUG, shown as a hint so manual
  /// testing works without a real SMS.  Null in production.
  final String? debugCode;

  const OtpVerifyScreen({
    super.key,
    required this.phone,
    this.name,
    this.debugCode,
  });

  @override
  State<OtpVerifyScreen> createState() => _OtpVerifyScreenState();
}

class _OtpVerifyScreenState extends State<OtpVerifyScreen> {
  final _formKey  = GlobalKey<FormState>();
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = context.read<AuthProvider>();
    await auth.verifyOtp(
      widget.phone,
      _codeCtrl.text.trim(),
      name: widget.name,
    );
    if (!mounted) return;
    if (auth.isLoggedIn) {
      Navigator.of(context).pushNamedAndRemoveUntil(
        auth.isNewAccount ? '/profile-setup' : '/tournaments',
        (_) => false,
      );
    }
  }

  Future<void> _resend() async {
    final auth = context.read<AuthProvider>();
    await auth.requestOtp(widget.phone);
    if (!mounted) return;
    if (auth.error == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A new code was sent.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth  = context.watch<AuthProvider>();
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Enter code')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(32),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'We sent a 6-digit code to\n${widget.phone}',
                    style: theme.textTheme.bodyLarge,
                    textAlign: TextAlign.center,
                  ),
                  if (widget.debugCode != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Dev code: ${widget.debugCode}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                  const SizedBox(height: 32),

                  GolfTextField(
                    controller: _codeCtrl,
                    label: 'Code',
                    hint: '123456',
                    prefixIcon: Icons.sms_outlined,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    autocorrect: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                    onFieldSubmitted: (_) => _verify(),
                    validator: (v) =>
                        (v == null || v.trim().length != 6)
                            ? 'Enter the 6-digit code'
                            : null,
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
                    label: 'Verify',
                    loading: auth.loading,
                    onPressed: _verify,
                    height: 48,
                  ),
                  const SizedBox(height: 16),

                  TextButton(
                    onPressed: auth.loading ? null : _resend,
                    child: const Text('Resend code'),
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
