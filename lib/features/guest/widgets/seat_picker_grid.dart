import 'package:flutter/material.dart';

enum DemoSeatStatus { available, booked, occupied, blocked, cleaning }

class DemoSeat {
  const DemoSeat({required this.id, required this.seatNumber, required this.status});
  final String id;
  final int seatNumber;
  final DemoSeatStatus status;
}

class DemoTable {
  const DemoTable({required this.tableNumber, required this.seats});
  final int tableNumber;
  final List<DemoSeat> seats;
}

/// Real, working seat-grid widget (the "BookMyShow-style seat picker" named
/// in project-spec.md), fed with sample data for now since there's no live
/// event to query yet. Selection is capped at partySize, matching the
/// "group bookings are atomic" rule — you pick exactly the party size,
/// not a partial set.
class SeatPickerGrid extends StatelessWidget {
  const SeatPickerGrid({
    super.key,
    required this.tables,
    required this.selectedSeatIds,
    required this.partySize,
    required this.onToggle,
  });

  final List<DemoTable> tables;
  final Set<String> selectedSeatIds;
  final int partySize;
  final ValueChanged<String> onToggle;

  Color _colorFor(BuildContext context, DemoSeatStatus status, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    if (selected) return scheme.primary;
    switch (status) {
      case DemoSeatStatus.available:
        return scheme.surfaceContainerHighest;
      case DemoSeatStatus.booked:
      case DemoSeatStatus.occupied:
        return scheme.errorContainer;
      case DemoSeatStatus.blocked:
      case DemoSeatStatus.cleaning:
        return scheme.surfaceContainerHigh;
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final table in tables) ...[
          Text('Table ${table.tableNumber}', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final seat in table.seats)
                _SeatBox(
                  label: '${seat.seatNumber}',
                  color: _colorFor(context, seat.status, selectedSeatIds.contains(seat.id)),
                  enabled: seat.status == DemoSeatStatus.available &&
                      (selectedSeatIds.contains(seat.id) || selectedSeatIds.length < partySize),
                  onTap: seat.status == DemoSeatStatus.available
                      ? () => onToggle(seat.id)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }
}

class _SeatBox extends StatelessWidget {
  const _SeatBox({required this.label, required this.color, required this.enabled, this.onTap});
  final String label;
  final Color color;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(8),
      child: Opacity(
        opacity: enabled || onTap == null ? 1 : 0.4,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(label, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}
