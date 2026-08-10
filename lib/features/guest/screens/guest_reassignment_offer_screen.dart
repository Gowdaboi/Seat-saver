import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

/// Real accept/reject countdown, per the design locked in during planning
/// (project-spec.md "Resolved decisions"): subscribes via Realtime to the
/// guest's own reassignment_offers (RLS already scopes this to their own
/// rows), and reacts to whatever's currently 'offered'. The ring is
/// cosmetic — expires_at is the server-side source of truth, enforced by
/// expire_reassignment_offers() on a pg_cron schedule (0003_reassignment_engine.sql).
class GuestReassignmentOfferScreen extends StatefulWidget {
  const GuestReassignmentOfferScreen({super.key});

  @override
  State<GuestReassignmentOfferScreen> createState() => _GuestReassignmentOfferScreenState();
}

class _GuestReassignmentOfferScreenState extends State<GuestReassignmentOfferScreen> {
  Stream<List<Map<String, dynamic>>>? _stream;
  String? _error;

  Timer? _ticker;
  DateTime? _tickingExpiresAt;
  Duration _remaining = Duration.zero;

  String? _windowOfferId;
  int _windowSeconds = 60;

  bool _responding = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final userId = supabase.auth.currentUser?.id;
      if (userId == null) throw StateError('Not verified yet');
      final guest = await supabase.from('guests').select('id').eq('auth_user_id', userId).single();
      setState(() {
        _stream = supabase
            .from('reassignment_offers')
            .stream(primaryKey: ['id'])
            .eq('offered_to_guest_id', guest['id']);
      });
    } catch (e) {
      setState(() => _error = 'Could not reach Supabase: $e');
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _syncTicker(DateTime? expiresAt) {
    if (_tickingExpiresAt == expiresAt) return;
    _ticker?.cancel();
    _tickingExpiresAt = expiresAt;
    if (expiresAt == null) {
      _remaining = Duration.zero;
      return;
    }
    _remaining = expiresAt.difference(DateTime.now());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final rem = expiresAt.difference(DateTime.now());
      if (mounted) setState(() => _remaining = rem.isNegative ? Duration.zero : rem);
    });
  }

  Future<void> _loadWindowSeconds(String offerId) async {
    if (_windowOfferId == offerId) return;
    _windowOfferId = offerId;
    try {
      final row = await supabase
          .from('reassignment_offer_seats')
          .select('seats(tables(events(reassignment_response_minutes)))')
          .eq('offer_id', offerId)
          .limit(1)
          .single();
      final minutes =
          (((row['seats'] as Map)['tables'] as Map)['events'] as Map)['reassignment_response_minutes'] as int;
      if (mounted) setState(() => _windowSeconds = minutes * 60);
    } catch (_) {
      // cosmetic only — fall back to the default ring scale on failure
    }
  }

  Future<void> _respond(String offerId, String rpcName) async {
    setState(() {
      _responding = true;
      _status = null;
    });
    try {
      await supabase.rpc(rpcName, params: {'p_offer_id': offerId});
      setState(() => _status = 'Sent.');
    } catch (e) {
      setState(() => _status = 'Could not respond: $e');
    } finally {
      if (mounted) setState(() => _responding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Seat offer')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : _stream == null
              ? const Center(child: CircularProgressIndicator())
              : StreamBuilder<List<Map<String, dynamic>>>(
                  stream: _stream,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final offered = snapshot.data!.where((r) => r['status'] == 'offered').toList();
                    if (offered.isEmpty) {
                      _syncTicker(null);
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No active seat offer right now.', textAlign: TextAlign.center),
                        ),
                      );
                    }

                    final offer = offered.first;
                    final offerId = offer['id'] as String;
                    final expiresAt = DateTime.parse(offer['expires_at'] as String);
                    _syncTicker(expiresAt);
                    _loadWindowSeconds(offerId);

                    final expired = _remaining == Duration.zero;
                    final seconds = _remaining.inSeconds;

                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Text('A seat has opened up for your party'),
                            const SizedBox(height: 24),
                            SizedBox(
                              width: 120,
                              height: 120,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  CircularProgressIndicator(
                                    value: (seconds / _windowSeconds).clamp(0, 1),
                                    strokeWidth: 6,
                                  ),
                                  Text(expired ? 'Expired' : '${seconds}s'),
                                ],
                              ),
                            ),
                            const SizedBox(height: 24),
                            if (_status != null) ...[
                              Text(_status!, textAlign: TextAlign.center),
                              const SizedBox(height: 12),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                OutlinedButton(
                                  onPressed: expired || _responding
                                      ? null
                                      : () => _respond(offerId, 'reject_reassignment_offer'),
                                  child: const Text('Decline'),
                                ),
                                const SizedBox(width: 16),
                                FilledButton(
                                  onPressed: expired || _responding
                                      ? null
                                      : () => _respond(offerId, 'accept_reassignment_offer'),
                                  child: const Text('Accept'),
                                ),
                              ],
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
