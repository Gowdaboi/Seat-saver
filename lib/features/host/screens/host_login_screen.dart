import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors.dart';
import '../../../core/supabase_client.dart';
import '../widgets/resend_confirmation.dart';

class HostLoginScreen extends StatefulWidget {
  const HostLoginScreen({super.key});

  @override
  State<HostLoginScreen> createState() => _HostLoginScreenState();
}

class _HostLoginScreenState extends State<HostLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  String? _error;

  /// Set when the sign-in failed specifically because the address was never
  /// confirmed. That is the one failure a person can fix from this screen,
  /// and the one where "wrong email or password" would be actively
  /// misleading — the credentials are fine.
  bool _needsConfirmation = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
      _needsConfirmation = false;
    });
    try {
      await supabase.auth.signInWithPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );
      // Tells the platform the autofill session finished successfully, which
      // is what prompts a browser or password manager to offer to save these
      // credentials. Without it the fields are merely fillable, never
      // savable — the manager has no signal that the sign-in worked.
      TextInput.finishAutofillContext();

      // first login after email confirmation is what actually creates the
      // caterers row — see ensureCatererProfile() for why this can't
      // happen at signUp() time.
      await ensureCatererProfile();
      if (mounted) context.go('/host/dashboard');
    } on AuthException catch (e) {
      final unconfirmed = isEmailNotConfirmed(e);
      setState(() {
        _needsConfirmation = unconfirmed;
        _error = unconfirmed
            ? 'This email has not been confirmed yet. Use the link in your '
                  'confirmation email, or send yourself a new one.'
            : e.message;
      });
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Host log in')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              // AutofillGroup is what makes the browser treat these two fields
              // as one credential pair. Flutter web renders a hidden DOM input
              // per field carrying the `autocomplete` attribute derived from
              // autofillHints below — that markup is what a password manager
              // actually looks for. There is no literal <form> to hang an
              // onSubmit on: the app draws to canvas, so the DOM inputs exist
              // only to serve autofill and IME.
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      // username first: managers key the saved entry off it, and
                      // email alone gets treated as a contact field on some.
                      autofillHints: const [AutofillHints.username, AutofillHints.email],
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(labelText: 'Email'),
                      validator: (v) =>
                          (v == null || !v.contains('@')) ? 'Enter a valid email' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      // Enter submits, which is both the expected keyboard
                      // behaviour and a second thing managers watch for. The
                      // button alone never gave the form a completion event.
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (!_submitting) _submit();
                      },
                      decoration: const InputDecoration(labelText: 'Password'),
                      validator: (v) =>
                          (v == null || v.length < 6) ? 'At least 6 characters' : null,
                    ),
                    const SizedBox(height: 20),
                    if (_error != null) ...[
                      Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      if (_needsConfirmation) ...[
                        const SizedBox(height: 12),
                        ResendConfirmationButton(email: _emailController.text.trim()),
                      ],
                      const SizedBox(height: 12),
                    ],
                    FilledButton(
                      onPressed: _submitting ? null : _submit,
                      child: _submitting
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Log in'),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => context.go('/host/signup'),
                      child: const Text("New caterer? Sign up"),
                    ),
                    TextButton(
                      onPressed: () => context.go('/host/forgot-password'),
                      child: const Text('Forgot password?'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
