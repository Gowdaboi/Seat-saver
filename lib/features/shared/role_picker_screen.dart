import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_url.dart';

/// Host entry point. Real guests never see this screen — they always
/// arrive via a scanned QR code that deep-links straight to /e/:eventId
/// (see HostEventQrScreen), which carries the event id through the whole
/// guest flow. This screen exists purely for the host side.
class RolePickerScreen extends StatelessWidget {
  const RolePickerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // A confirmation or recovery link that has expired lands here
                // with the reason buried in the URL and nothing on screen —
                // which reads as "the link goes nowhere". Say what happened.
                if (authErrorFromUrl() case final message?) ...[
                  _LinkProblem(message: message),
                  const SizedBox(height: 24),
                ],
                const Icon(Icons.event_seat, size: 64),
                const SizedBox(height: 16),
                Text(
                  'Catering Seating & Rounds',
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: () => context.go('/host/login'),
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                    child: Text("I'm hosting an event"),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "Guests: scan the QR code at your event to get started.",
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shown when someone arrives from a confirmation or recovery link that
/// Supabase rejected. The provider's own wording is used rather than a
/// paraphrase — "Email link is invalid or has expired" already says the
/// useful part — with the next step spelled out underneath, since the reason
/// alone doesn't tell anyone what to do about it.
class _LinkProblem extends StatelessWidget {
  const _LinkProblem({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.link_off, color: scheme.onErrorContainer),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Confirmation links can only be used once, and expire after a '
            'while. Sign up again with the same email to get a fresh one, or '
            'use "Forgot password" if your account already exists.',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}
