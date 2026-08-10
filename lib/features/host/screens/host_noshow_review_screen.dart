import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

/// Real wiring against host_pending_noshow_bookings and
/// mark_booking_no_show() (see supabase/migrations/0004_noshow_host_flow.sql).
/// The X-minute timeout doesn't auto-release seats — this screen is exactly
/// the "informed to the host" step; marking a booking here is what actually
/// releases the group into the reassignment queue.
class HostNoShowReviewScreen extends StatefulWidget {
  const HostNoShowReviewScreen({super.key});

  @override
  State<HostNoShowReviewScreen> createState() => _HostNoShowReviewScreenState();
}

class _HostNoShowReviewScreenState extends State<HostNoShowReviewScreen> {
  List<Map<String, dynamic>>? _rows;
  String? _error;
  String? _markingBookingId;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await supabase.from('host_pending_noshow_bookings').select();
      setState(() => _rows = List<Map<String, dynamic>>.from(rows));
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    }
  }

  Future<void> _markNoShow(String bookingId) async {
    setState(() => _markingBookingId = bookingId);
    try {
      await supabase.rpc('mark_booking_no_show', params: {'p_booking_id': bookingId});
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not mark no-show: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _markingBookingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('No-show review'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
      ),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _rows == null
              ? const Center(child: CircularProgressIndicator())
              : _rows!.isEmpty
                  ? const Center(child: Text('No pending no-show candidates right now.'))
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: _rows!.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) {
                        final row = _rows![i];
                        final bookingId = row['booking_id'] as String;
                        return Card(
                          child: ListTile(
                            leading: const Icon(Icons.person_off_outlined),
                            title: Text('Party of ${row['party_size']}'),
                            subtitle: Text(
                              'Round started ${row['round_started_at']}\n'
                              'Timeout: ${row['no_show_timeout_minutes']} min',
                            ),
                            isThreeLine: true,
                            trailing: FilledButton.tonal(
                              onPressed: _markingBookingId == bookingId
                                  ? null
                                  : () => _markNoShow(bookingId),
                              child: _markingBookingId == bookingId
                                  ? const SizedBox(
                                      height: 16, width: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Text('Mark no-show'),
                            ),
                          ),
                        );
                      },
                    ),
    );
  }
}
