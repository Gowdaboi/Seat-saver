import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/app_url.dart';
import '../../../core/supabase_client.dart';

/// Sends a password-reset email. The redirect link lands back on this app
/// with a recovery token; main.dart listens for AuthChangeEvent.passwordRecovery
/// globally and routes to HostResetPasswordScreen when it fires, regardless
/// of which page happens to be open at the time.
class HostForgotPasswordScreen extends StatefulWidget {
  const HostForgotPasswordScreen({super.key});

  @override
  State<HostForgotPasswordScreen> createState() => _HostForgotPasswordScreenState();
}

class _HostForgotPasswordScreenState extends State<HostForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _submitting = false;
  bool _sent = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailController.text.trim();
    if (!email.contains('@')) {
      setState(() => _error = 'Enter a valid email');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await supabase.auth.resetPasswordForEmail(
        email,
        // origin alone dropped the deployment's base path, so on GitHub Pages
        // the recovery link pointed at the account root rather than the app.
        redirectTo: appUrl('/host/reset-password'),
      );
      setState(() => _sent = true);
    } on AuthException catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _sent
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mark_email_unread_outlined, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'If that email has an account, a reset link is on its way.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      OutlinedButton(
                        onPressed: () => context.go('/host/login'),
                        child: const Text('Back to log in'),
                      ),
                    ],
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "Enter your account email and we'll send you a reset link.",
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(labelText: 'Email'),
                      ),
                      const SizedBox(height: 20),
                      if (_error != null) ...[
                        Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                        const SizedBox(height: 12),
                      ],
                      FilledButton(
                        onPressed: _submitting ? null : _submit,
                        child: _submitting
                            ? const SizedBox(
                                height: 18, width: 18,
                                child: CircularProgressIndicator(strokeWidth: 2))
                            : const Text('Send reset link'),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
