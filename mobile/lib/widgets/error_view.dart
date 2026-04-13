/// widgets/error_view.dart
/// Reusable error state widget with an icon, message, and optional retry button.

import 'package:flutter/material.dart';
import '../api/client.dart';

/// Returns a user-friendly message for any exception thrown by ApiClient.
String friendlyError(Object error) {
  if (error is NetworkException) {
    return error.message; // already friendly
  }
  if (error is AuthException) {
    return 'Your session has expired. Please sign in again.';
  }
  if (error is ApiException) {
    return error.message.isNotEmpty ? error.message : 'Server error.';
  }
  return error.toString();
}

/// Returns true when the error is a connectivity/timeout problem.
bool isNetworkError(Object error) => error is NetworkException;

/// Returns true when the error is a 401 auth failure.
bool isAuthError(Object error) => error is AuthException;

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  /// Pass [isNetwork: true] to show a wifi-off icon instead of the default warning.
  final bool isNetwork;

  const ErrorView({
    super.key,
    required this.message,
    this.onRetry,
    this.isNetwork = false,
  });

  /// Convenience constructor that picks icon and message from the exception type.
  factory ErrorView.fromError(
    Object error, {
    Key? key,
    VoidCallback? onRetry,
  }) {
    return ErrorView(
      key: key,
      message: friendlyError(error),
      onRetry: onRetry,
      isNetwork: isNetworkError(error),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isNetwork ? Icons.wifi_off_rounded : Icons.error_outline_rounded,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurface,
              ),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
