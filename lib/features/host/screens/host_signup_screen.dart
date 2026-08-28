import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/app_url.dart';
import '../../../core/supabase_client.dart';
import '../widgets/resend_confirmation.dart';

/// Signs up a new caterer. business_name is passed as auth user metadata
/// (not written to `caterers` directly here) because with "Confirm email"
/// enabled on the Supabase project, signUp() doesn't establish a session —
/// there's no auth.uid() yet for the caterers_insert_own RLS check to match,
/// so the profile row can't be created until the user actually confirms
/// and logs in (see ensureCatererProfile(), called from the login screen).
class HostSignUpScreen extends StatefulWidget {
  const HostSignUpScreen({super.key});

  @override
  State<HostSignUpScreen> createState() => _HostSignUpScreenState();
}

class _HostSignUpScreenState extends State<HostSignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _businessNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _submitting = false;
  bool _awaitingConfirmation = false;
  bool _alreadyRegistered = false;
  String? _error;

  @override
  void dispose() {
    _businessNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
      _alreadyRegistered = false;
    });
    try {
      final email = _emailController.text.trim();
      final res = await supabase.auth.signUp(
        email: email,
        password: _passwordController.text,
        data: {'business_name': _businessNameController.text.trim()},
        // Without this, Supabase falls back to the project's single Site URL
        // — which was localhost, so every confirmation email sent to anyone
        // but the developer linked to a machine they do not have (issue #1).
        // Derived from the running page, so a build served from Pages mails
        // Pages links and a local build mails local ones.
        emailRedirectTo: appUrl('/host/login'),
      );

      // Supabase deliberately doesn't return a distinct "email taken" error
      // for signUp() — that would let a stranger probe arbitrary emails to
      // find out who has an account. The documented signal instead: signing
      // up with an email that already has an identity returns a user object
      // with an empty `identities` list (no *new* identity was created).
      if (res.user != null && (res.user!.identities?.isEmpty ?? false)) {
        setState(() => _alreadyRegistered = true);
        return;
      }

      // An account now exists, whichever branch follows — so this is the
      // moment a manager should offer to save the new credentials. It sits
      // after the already-registered check above deliberately: that path
      // creates nothing, and prompting to save there would offer to
      // overwrite a working entry with a password that does not open it.
      TextInput.finishAutofillContext();

      if (res.session != null) {
        // confirm-email is off (or already confirmed) — a real session
        // exists right away, so the profile can be created now.
        await ensureCatererProfile();
        if (mounted) context.go('/host/dashboard');
      } else {
        setState(() => _awaitingConfirmation = true);
      }
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
      appBar: AppBar(title: const Text('Caterer sign up')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _awaitingConfirmation
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.mark_email_unread_outlined, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        "Check your email and click the confirmation link, "
                        "then come back and log in.",
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => context.go('/host/login'),
                        child: const Text('Go to log in'),
                      ),
                      const SizedBox(height: 16),
                      // Right here, while the address is still on screen and
                      // known to be correct — the point at which someone
                      // realises nothing has arrived.
                      ResendConfirmationButton(email: _emailController.text.trim()),
                    ],
                  )
                : _alreadyRegistered
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.person_outline, size: 48),
                      const SizedBox(height: 16),
                      const Text(
                        'An account with this email already exists.',
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: () => context.go('/host/login'),
                        child: const Text('Log in instead'),
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => setState(() => _alreadyRegistered = false),
                        child: const Text('Use a different email'),
                      ),
                    ],
                  )
                : Form(
                    key: _formKey,
                    // Same mechanism as the login screen: Flutter emits a
                    // real <form> of hidden inputs carrying autocomplete
                    // attributes for every field in the group, which is
                    // what a password manager reads.
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          TextFormField(
                            controller: _businessNameController,
                            autofillHints: const [AutofillHints.organizationName],
                            textInputAction: TextInputAction.next,
                            decoration: const InputDecoration(labelText: 'Business name'),
                            validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
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
                            // newPassword, not password: this is where a
                            // manager offers to *generate* one, and where
                            // most saved entries are actually created.
                            // Marking it `password` would instead invite it
                            // to fill an existing credential into a field
                            // that is creating a new account.
                            autofillHints: const [AutofillHints.newPassword],
                            textInputAction: TextInputAction.done,
                            onFieldSubmitted: (_) {
                              if (!_submitting) _submit();
                            },
                            decoration: const InputDecoration(
                              labelText: 'Password',
                              helperText: 'At least 8 characters, with letters and numbers',
                              helperMaxLines: 2,
                            ),
                            validator: (v) {
                              if (v == null || v.length < 8) return 'At least 8 characters';
                              final hasLetter = v.contains(RegExp(r'[A-Za-z]'));
                              final hasDigit = v.contains(RegExp(r'[0-9]'));
                              if (!hasLetter || !hasDigit) {
                                return 'Include both letters and numbers';
                              }
                              return null;
                            },
                          ),
                          const SizedBox(height: 20),
                          if (_error != null) ...[
                            Text(
                              _error!,
                              style: TextStyle(color: Theme.of(context).colorScheme.error),
                            ),
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
                                : const Text('Sign up'),
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
