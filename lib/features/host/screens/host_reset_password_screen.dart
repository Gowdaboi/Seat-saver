import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_client.dart';

/// Reached via the recovery-link redirect (see main.dart's
/// AuthChangeEvent.passwordRecovery listener) or directly if already in a
/// recovery session. Same password rule as signup: at least 8 characters,
/// letters and numbers.
class HostResetPasswordScreen extends StatefulWidget {
  const HostResetPasswordScreen({super.key});

  @override
  State<HostResetPasswordScreen> createState() => _HostResetPasswordScreenState();
}

class _HostResetPasswordScreenState extends State<HostResetPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await supabase.auth.updateUser(UserAttributes(password: _passwordController.text));
      await ensureCatererProfile();
      if (mounted) context.go('/host/dashboard');
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
      appBar: AppBar(title: const Text('Set a new password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: 'New password',
                      helperText: 'At least 8 characters, with letters and numbers',
                      helperMaxLines: 2,
                    ),
                    validator: (v) {
                      if (v == null || v.length < 8) return 'At least 8 characters';
                      final hasLetter = v.contains(RegExp(r'[A-Za-z]'));
                      final hasDigit = v.contains(RegExp(r'[0-9]'));
                      if (!hasLetter || !hasDigit) return 'Include both letters and numbers';
                      return null;
                    },
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
                        : const Text('Update password'),
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
