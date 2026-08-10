import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../core/supabase_client.dart';

/// Real camera + QR decode + check-in. The scanned QR encodes only
/// booking_id (see guest_booking_confirmation_screen.dart); everything
/// else — does this booking belong to one of my events, is it for the
/// round happening right now — is validated server-side in
/// check_in_booking() (supabase/migrations/0006_seat_checkin.sql), not
/// trusted from the QR content itself.
class HostSeatScanScreen extends StatefulWidget {
  const HostSeatScanScreen({super.key});

  @override
  State<HostSeatScanScreen> createState() => _HostSeatScanScreenState();
}

enum _ResultKind { success, error }

class _HostSeatScanScreenState extends State<HostSeatScanScreen> {
  String? _lastProcessedCode;
  bool _processing = false;
  _ResultKind? _resultKind;
  String? _resultMessage;

  Future<void> _handleDetect(BarcodeCapture capture) async {
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null || code == _lastProcessedCode || _processing) return;

    setState(() {
      _lastProcessedCode = code;
      _processing = true;
      _resultKind = null;
      _resultMessage = null;
    });

    try {
      final bookingId = (jsonDecode(code) as Map<String, dynamic>)['booking_id'] as String?;
      if (bookingId == null) {
        throw const FormatException('Not a booking QR code');
      }
      final result = await supabase.rpc('check_in_booking', params: {'p_booking_id': bookingId}) as Map;
      final seats = List<Map<String, dynamic>>.from(result['seats'] as List);
      final seatLabels = seats.map((s) => 'T${s['table_number']}·${s['seat_number']}').join(', ');
      setState(() {
        _resultKind = _ResultKind.success;
        _resultMessage =
            'Seated: ${result['guest_name'] ?? 'Guest'} (party of ${result['party_size']})\n$seatLabels';
      });
    } catch (e) {
      setState(() {
        _resultKind = _ResultKind.error;
        _resultMessage = e is FormatException ? e.message : 'Could not check in: $e';
      });
    } finally {
      if (mounted) setState(() => _processing = false);
    }
  }

  void _scanNext() {
    setState(() {
      _lastProcessedCode = null;
      _resultKind = null;
      _resultMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan arrival QR')),
      body: Column(
        children: [
          Expanded(child: MobileScanner(onDetect: _handleDetect)),
          Container(
            width: double.infinity,
            color: _resultKind == _ResultKind.success
                ? Colors.green.shade100
                : _resultKind == _ResultKind.error
                    ? Colors.red.shade100
                    : null,
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                if (_processing)
                  const CircularProgressIndicator()
                else
                  Text(
                    _resultMessage ?? "Point the camera at a guest's confirmation QR",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontWeight: _resultKind != null ? FontWeight.bold : FontWeight.normal,
                      color: _resultKind == _ResultKind.success
                          ? Colors.green.shade900
                          : _resultKind == _ResultKind.error
                              ? Colors.red.shade900
                              : null,
                    ),
                  ),
                if (_resultKind != null && !_processing) ...[
                  const SizedBox(height: 12),
                  FilledButton(onPressed: _scanNext, child: const Text('Scan next')),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
