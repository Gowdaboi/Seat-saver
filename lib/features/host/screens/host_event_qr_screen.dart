import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../widgets/event_picker.dart';

/// The QR a host prints/displays at the venue. Scanning it opens the app
/// straight to /e/:eventId — no role picker, no typing an event code.
/// Uses the app's own current origin (Uri.base.origin) so this works
/// wherever the app happens to be hosted, without a separate config value
/// to keep in sync.
class HostEventQrScreen extends StatelessWidget {
  const HostEventQrScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Event QR code')),
      body: EventPicker(
        builder: (context, eventId) {
          final url = '${Uri.base.origin}/#/e/$eventId';
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Guests scan this to open the app straight into this event — '
                    'menu, floor layout, and seat booking, no typing required.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(data: url, size: 240, backgroundColor: Colors.white),
                  ),
                  const SizedBox(height: 16),
                  SelectableText(
                    url,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
