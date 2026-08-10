import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

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
