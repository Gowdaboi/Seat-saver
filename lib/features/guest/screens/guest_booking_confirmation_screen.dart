import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/supabase_client.dart';

/// Real QR generation from the actual booking just created. The QR
/// deliberately encodes only booking_id — NOT seat_ids or round_id. For
/// Pankti events, round_id isn't set on the booking until the host starts
/// a round (well after this QR is generated), so baking it in here would
/// make the code permanently stale. Core rule #3 (QR replay protection —
/// must match the current active round) is instead checked live, server
/// side, on every scan (see supabase/migrations/0006_seat_checkin.sql).
class GuestBookingConfirmationScreen extends StatefulWidget {
  const GuestBookingConfirmationScreen({super.key, required this.bookingId});
  final String bookingId;

  @override
  State<GuestBookingConfirmationScreen> createState() => _GuestBookingConfirmationScreenState();
}

class _GuestBookingConfirmationScreenState extends State<GuestBookingConfirmationScreen> {
  String? _payload;
  List<String>? _seatLabels;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final seatRows = await supabase
          .from('booking_seats')
          .select('seats(seat_number, tables(table_number))')
          .eq('booking_id', widget.bookingId);

      final labels = [
        for (final s in List<Map<String, dynamic>>.from(seatRows))
          'Table ${(s['seats'] as Map)['tables']['table_number']} · Seat ${(s['seats'] as Map)['seat_number']}',
      ];

      setState(() {
        _payload = jsonEncode({'booking_id': widget.bookingId});
        _seatLabels = labels;
      });
    } catch (e) {
      setState(() => _error = 'Could not load booking: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Booking confirmed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _error != null
              ? Text(_error!, textAlign: TextAlign.center)
              : _payload == null
                  ? const CircularProgressIndicator()
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_seatLabels!.join(', '), textAlign: TextAlign.center),
                        const SizedBox(height: 8),
                        const Text('Show this at your seat when you arrive'),
                        const SizedBox(height: 24),
                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: QrImageView(
                            data: _payload!,
                            size: 220,
                            backgroundColor: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          "Seat opens up if you're not scanned in within the "
                          "no-show timeout — the host reviews and confirms this, "
                          "it isn't automatic.",
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
        ),
      ),
    );
  }
}
