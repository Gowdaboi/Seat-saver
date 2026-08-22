import 'package:flutter/material.dart';

import '../../../core/supabase_client.dart';

/// The page the "can't make it?" link in a round reminder opens.
///
/// Deliberately the only screen in the app that works with no session at
/// all. A guest reading an SMS may be on a phone that never logged in — and
/// asking them to sign in first would mean the seat stays held by whoever
/// gave up on the flow. The token in the URL is the whole authorisation:
/// it proves nothing about who is holding it, only that this booking's own
/// message was sent to them, and the two RPCs behind it can reach exactly
/// that one booking (see 0015_round_reminders.sql).
class GuestCancelBookingScreen extends StatefulWidget {
  const GuestCancelBookingScreen({super.key, required this.token});
  final String token;

  @override
  State<GuestCancelBookingScreen> createState() => _GuestCancelBookingScreenState();
}

class _GuestCancelBookingScreenState extends State<GuestCancelBookingScreen> {
  Map<String, dynamic>? _booking;
  bool _loading = true;
  bool _cancelling = false;
  String? _error;

  /// Outcome code from cancel_booking_by_token, once the guest has acted.
  String? _outcome;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await supabase.rpc(
        'get_booking_by_cancel_token',
        params: {'p_token': widget.token},
      );
      final list = List<Map<String, dynamic>>.from(rows as List);
      if (!mounted) return;
      setState(() {
        _booking = list.isEmpty ? null : list.first;
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not open this link: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _cancel() async {
    setState(() => _cancelling = true);
    try {
      final outcome = await supabase.rpc(
        'cancel_booking_by_token',
        params: {'p_token': widget.token},
      ) as String;
      if (!mounted) return;
      setState(() => _outcome = outcome);
      // Re-read so the summary below reflects the booking's new state
      // rather than the one we opened the page with.
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not cancel: $e')));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your booking')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _body(),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text(_error!, textAlign: TextAlign.center));

    // No row means the token matched nothing. An expired, mistyped or made-up
    // link all land here and all say the same thing — there is nothing worth
    // telling apart, and saying more would help someone guessing at tokens.
    if (_booking == null) {
      return const Center(
        child: Text(
          "This link isn't valid any more.\n\n"
          'If you still need to change your booking, please speak to the host.',
          textAlign: TextAlign.center,
        ),
      );
    }

    final booking = _booking!;
    final status = booking['booking_status'] as String;
    final cancellable = booking['cancellable'] as bool;
    final theme = Theme.of(context);

    return ListView(
      shrinkWrap: true,
      children: [
        if (_outcome != null) ...[
          _outcomeBanner(_outcome!),
          const SizedBox(height: 24),
        ],
        Text(booking['event_name'] as String, style: theme.textTheme.headlineSmall),
        const SizedBox(height: 4),
        Text(booking['venue_name'] as String, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 24),
        _row('Booked for', booking['guest_name'] as String? ?? '—'),
        if (booking['round_number'] != null) _row('Round', '${booking['round_number']}'),
        _row('Party size', '${booking['party_size']}'),
        _row(
          'Seats',
          (List<String>.from(booking['seat_labels'] as List? ?? const []))
              .join('\n')
              .ifEmpty('—'),
        ),
        _row('Status', _statusLabel(status)),
        const SizedBox(height: 32),
        if (cancellable) ...[
          Text(
            'Cancelling frees your seats immediately so the host can offer '
            'them to someone else. It cannot be undone from this link.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _cancelling ? null : _confirmCancel,
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
            child: _cancelling
                ? const SizedBox(
                    height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Cancel my booking'),
          ),
        ] else if (_outcome == null)
          Text(
            status == 'cancelled'
                ? 'This booking has already been cancelled — nothing more to do.'
                : 'This booking can no longer be cancelled from here. '
                    'Please speak to the host.',
            style: theme.textTheme.bodyMedium,
          ),
      ],
    );
  }

  Future<void> _confirmCancel() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel your booking?'),
        content: const Text(
          'Your seats will be released straight away and given to other guests.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep my booking'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yes, cancel'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _cancel();
  }

  Widget _outcomeBanner(String outcome) {
    final theme = Theme.of(context);
    late final IconData icon;
    late final Color color;
    late final String message;

    switch (outcome) {
      case 'cancelled':
        icon = Icons.check_circle;
        color = Colors.green;
        message = 'Your booking is cancelled and your seats are free. Thank you '
            'for letting us know.';
        break;
      case 'already_cancelled':
        icon = Icons.info_outline;
        color = theme.colorScheme.primary;
        message = 'This booking was already cancelled.';
        break;
      case 'too_late':
        icon = Icons.schedule;
        color = theme.colorScheme.error;
        message = 'This booking can no longer be cancelled — the round has '
            'already started or your seats are in use. Please speak to the host.';
        break;
      default:
        icon = Icons.error_outline;
        color = theme.colorScheme.error;
        message = "We couldn't find that booking.";
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: 12),
          Expanded(child: Text(message)),
        ],
      ),
    );
  }

  Widget _row(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  String _statusLabel(String status) {
    switch (status) {
      case 'requested':
        return 'Requested';
      case 'confirmed':
        return 'Confirmed';
      case 'cancelled':
        return 'Cancelled';
      case 'no_show':
        return 'Marked as no-show';
      default:
        return status;
    }
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
