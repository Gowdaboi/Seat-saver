import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/app_url.dart';
import '../../../core/supabase_client.dart';

/// "Send it again" for a signup confirmation email.
///
/// Confirmation links are single-use and expire, and the first one can simply
/// not arrive — caught in spam, mistyped address, or consumed by a mail
/// scanner that follows links before the person ever sees them. Without this
/// the only recovery was to sign up again with the same address, which the
/// app answers with "an account with this email already exists" — a dead end.
///
/// The redirect is rebuilt here rather than relying on the project's Site URL,
/// for the reason in [appUrl]: a single fixed setting cannot be right for both
/// a local build and the hosted one (issue #1).
class ResendConfirmationButton extends StatefulWidget {
  const ResendConfirmationButton({super.key, required this.email});

  final String email;

  @override
  State<ResendConfirmationButton> createState() => _ResendConfirmationButtonState();
}

class _ResendConfirmationButtonState extends State<ResendConfirmationButton> {
  bool _sending = false;
  String? _message;
  bool _failed = false;

  /// Supabase's built-in mailer allows very few sends per hour, and a second
  /// request inside the window is rejected rather than queued. Holding the
  /// button after a success stops someone burning that allowance on clicks
  /// that were never going to send.
  int _cooldown = 0;
  Timer? _ticker;

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _startCooldown() {
    _ticker?.cancel();
    setState(() => _cooldown = 60);
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return t.cancel();
      setState(() => _cooldown--);
      if (_cooldown <= 0) t.cancel();
    });
  }

  Future<void> _resend() async {
    setState(() {
      _sending = true;
      _message = null;
      _failed = false;
    });
    try {
      await supabase.auth.resend(
        type: OtpType.signup,
        email: widget.email,
        emailRedirectTo: appUrl('/host/login'),
      );
      if (!mounted) return;
      setState(() {
        _message = 'Sent. Check your inbox, and your spam folder.';
        _failed = false;
      });
      _startCooldown();
    } on AuthException catch (e) {
      if (!mounted) return;
      setState(() {
        // The rate-limit refusal is the one people will actually hit, and
        // Supabase's own wording for it is clear enough to pass through.
        _message = e.message;
        _failed = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _message = 'Could not reach Supabase: $e';
        _failed = true;
      });
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final waiting = _cooldown > 0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        OutlinedButton.icon(
          onPressed: (_sending || waiting) ? null : _resend,
          icon: _sending
              ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.mail_outline, size: 18),
          label: Text(
            waiting ? 'Resend in ${_cooldown}s' : 'Resend confirmation email',
          ),
        ),
        if (_message != null) ...[
          const SizedBox(height: 8),
          Text(
            _message!,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: _failed ? scheme.error : scheme.onSurfaceVariant,
                ),
          ),
        ],
      ],
    );
  }
}
