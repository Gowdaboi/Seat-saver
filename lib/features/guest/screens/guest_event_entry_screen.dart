import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../core/supabase_client.dart';

/// Real QR landing page: fetches the event's public info via
/// get_public_event_info() (callable before login — see
/// supabase/migrations/0005_guest_booking.sql for why this is a narrow RPC
/// rather than a broad anon SELECT grant on `events`).
class GuestEventEntryScreen extends StatefulWidget {
  const GuestEventEntryScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<GuestEventEntryScreen> createState() => _GuestEventEntryScreenState();
}

class _GuestEventEntryScreenState extends State<GuestEventEntryScreen> {
  Map<String, dynamic>? _event;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await supabase.rpc('get_public_event_info', params: {'p_event_id': widget.eventId});
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (list.isEmpty) {
        setState(() => _error = "This QR code doesn't match a known event.");
      } else {
        setState(() => _event = list.first);
      }
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null
              ? Text(_error!, textAlign: TextAlign.center)
              : _event == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.qr_code_scanner, size: 56),
                        const SizedBox(height: 16),
                        Text(
                          _event!['name'] as String,
                          style: Theme.of(context).textTheme.headlineSmall,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '${_event!['venue_name']} · ${_event!['date']}',
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        // An archived event is a real event that has finished,
                        // not a bad QR code — saying so stops someone going to
                        // find staff about a code that is working perfectly.
                        if (_event!['is_archived'] == true) ...[
                          Text(
                            'This event has ended and is no longer taking bookings.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Theme.of(context).colorScheme.error),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'If you think this is wrong, please speak to the host.',
                            textAlign: TextAlign.center,
                          ),
                        ] else ...[
                          const Text(
                            'Verify your phone number to view the menu, floor layout, '
                            'and book a seat for the next round.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: () => context.push('/e/${widget.eventId}/otp'),
                            child: const Padding(
                              padding: EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                              child: Text('Continue'),
                            ),
                          ),
                        ],
                      ],
                    ),
        ),
      ),
    );
  }
}
