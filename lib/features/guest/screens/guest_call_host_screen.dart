import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

/// Real insert into call_requests, scoped to the actual event the guest is
/// at. Also looks up the guest's own booked table (if any) so the host's
/// call-request list can show which table needs attention.
class GuestCallHostScreen extends StatefulWidget {
  const GuestCallHostScreen({super.key, required this.eventId});
  final String eventId;

  @override
  State<GuestCallHostScreen> createState() => _GuestCallHostScreenState();
}

class _GuestCallHostScreenState extends State<GuestCallHostScreen> {
  final _messageController = TextEditingController();
  bool _submitting = false;
  String? _status;

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _send(String type) async {
    setState(() {
      _submitting = true;
      _status = null;
    });
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw StateError('Not verified yet');
      final guest = await supabase
          .from('guests')
          .select('id')
          .eq('auth_user_id', userId)
          .single();

      final bookingSeat = await supabase
          .from('booking_seats')
          .select('seats(table_id), bookings!inner(event_id, guest_id)')
          .eq('bookings.event_id', widget.eventId)
          .eq('bookings.guest_id', guest['id'])
          .limit(1)
          .maybeSingle();
      final tableId = bookingSeat == null ? null : (bookingSeat['seats'] as Map)['table_id'] as String?;

      await supabase.from('call_requests').insert({
        'event_id': widget.eventId,
        'guest_id': guest['id'],
        'table_id': tableId,
        'type': type,
        'message': type == 'text' ? _messageController.text.trim() : null,
        'status': 'open',
      });
      setState(() => _status = 'Sent to the host.');
    } catch (e) {
      setState(() => _status = 'Could not reach Supabase: $e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Call host')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _messageController,
                  decoration: const InputDecoration(labelText: 'Message (optional)'),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),
                if (_status != null) ...[
                  Text(_status!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _submitting ? null : () => _send('text'),
                  icon: const Icon(Icons.message_outlined),
                  label: const Text('Send text request'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _submitting ? null : () => _send('call'),
                  icon: const Icon(Icons.call_outlined),
                  label: const Text('Flag for a call'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
