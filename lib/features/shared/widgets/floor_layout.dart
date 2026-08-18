import 'package:flutter/material.dart';

/// Whether a table's row of seats runs left-to-right or top-to-bottom in
/// the floor plan. "Table" here means a Pankti-style row of seats (banana
/// leaf style), not a round table people sit around — orientation is what
/// lets a host lay a hall out the way it's actually shaped.
enum TableOrientation { horizontal, vertical }

TableOrientation orientationFromString(String? s) =>
    s == 'vertical' ? TableOrientation.vertical : TableOrientation.horizontal;

/// Which of a table's two long sides actually has seats — 'both' for a
/// normal free-standing table, 'near' or 'far' for one pushed against a wall
/// or stage. Near/far, not left/right or top/bottom, because the meaning is
/// already orientation-relative: near is the top for a horizontal table and
/// the left for a vertical one (see _TableWidget).
enum SeatingSide { both, near, far }

SeatingSide seatingSideFromString(String? s) => SeatingSide.values.firstWhere(
      (v) => v.name == s,
      orElse: () => SeatingSide.both,
    );

/// Mirrors the seat_status enum. 'blocked' was removed in 0014: taking a
/// seat out of service is a fact about the floor plan, not a live state.
enum FloorSeatStatus { available, booked, occupied, cleaning }

/// Falls back to `cleaning` — the conservative choice, since an
/// unrecognised status must never render as bookable.
FloorSeatStatus seatStatusFromString(String s) => FloorSeatStatus.values.firstWhere(
      (v) => v.name == s,
      orElse: () => FloorSeatStatus.cleaning,
    );

class FloorSeat {
  const FloorSeat({required this.id, required this.seatNumber, required this.status});
  final String id;
  final int seatNumber;
  final FloorSeatStatus status;
}

class FloorTable {
  const FloorTable({
    required this.id,
    required this.tableNumber,
    required this.seats,
    this.gridRow = 0,
    this.gridCol = 0,
    this.orientation = TableOrientation.horizontal,
    this.seatingSide = SeatingSide.both,
  });
  final String id;
  final int tableNumber;
  final int gridRow;
  final int gridCol;
  final TableOrientation orientation;
  final SeatingSide seatingSide;
  final List<FloorSeat> seats;
}

/// Renders a section's tables at their actual grid positions — one row of
/// the widget per distinct grid_row, tables within a row ordered by
/// grid_col, each table drawn as a strip of seats running the way its own
/// orientation says. This is the single rendering used for the host's
/// design preview *and* the guest's seat picker, so what the host lays out
/// is pixel-for-pixel what the guest sees while booking.
///
/// Read-only preview: pass just [tables]. Interactive (the guest picker):
/// also pass [selectedSeatIds], [partySize], and [onToggleSeat] — an
/// available seat is tappable as long as it's already selected or the
/// party size hasn't been reached yet; anything not `available` never is.
class FloorLayoutView extends StatelessWidget {
  const FloorLayoutView({
    super.key,
    required this.tables,
    this.seatSize = 28,
    this.scrollVertically = true,
    this.padding = EdgeInsets.zero,
    this.selectedSeatIds,
    this.partySize,
    this.onToggleSeat,
    this.rowGap,
    this.showFacingLabels = false,
  });

  final List<FloorTable> tables;
  final double seatSize;

  /// Whether this widget wraps itself in a vertical scroll view. Pass false
  /// when the caller already provides scrolling (or wants the layout to
  /// just size to its content, e.g. inside a dialog's own scroll view).
  final bool scrollVertically;
  final EdgeInsets padding;

  final Set<String>? selectedSeatIds;
  final int? partySize;
  final void Function(String seatId)? onToggleSeat;

  /// Space left after the row at [gridRow] before the next one. Defaults to
  /// a flat 12px between every row; a hall-rows layout overrides this to
  /// alternate between a wide aisle and near-zero (backs touching), matching
  /// the physical rhythm of paired rows sharing one aisle.
  final double Function(int gridRow)? rowGap;

  /// Show which way a one-sided row's seats face (an arrow, derived from
  /// [SeatingSide] + [TableOrientation]) — meaningless for a two-sided
  /// table, so nothing is drawn when [FloorTable.seatingSide] is `both`.
  final bool showFacingLabels;

  @override
  Widget build(BuildContext context) {
    if (tables.isEmpty) return const SizedBox.shrink();

    final rowIndices = tables.map((t) => t.gridRow).toSet().toList()..sort();

    final content = Padding(
      padding: padding,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rowIndices) ...[
            _buildRow(context, row),
            if (row != rowIndices.last)
              SizedBox(height: rowGap?.call(row) ?? 12),
          ],
        ],
      ),
    );

    return scrollVertically ? SingleChildScrollView(child: content) : content;
  }

  Widget _buildRow(BuildContext context, int gridRow) {
    final tablesInRow = tables.where((t) => t.gridRow == gridRow).toList()
      ..sort((a, b) => a.gridCol.compareTo(b.gridCol));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final table in tablesInRow) ...[
            _TableWidget(
              table: table,
              seatSize: seatSize,
              selectedSeatIds: selectedSeatIds,
              partySize: partySize,
              onToggleSeat: onToggleSeat,
              showFacingLabel: showFacingLabels,
            ),
            if (table != tablesInRow.last) const SizedBox(width: 12),
          ],
        ],
      ),
    );
  }
}

class _TableWidget extends StatelessWidget {
  const _TableWidget({
    required this.table,
    required this.seatSize,
    this.selectedSeatIds,
    this.partySize,
    this.onToggleSeat,
    this.showFacingLabel = false,
  });

  final FloorTable table;
  final double seatSize;
  final Set<String>? selectedSeatIds;
  final int? partySize;
  final void Function(String seatId)? onToggleSeat;
  final bool showFacingLabel;

  /// A one-sided row's seats face away from its own bar, toward whichever
  /// side has no seats attached — the arrow points that way. `both` has
  /// seats on every side, so there's no single direction to show. A seated
  /// guest looks away from their own chair back — since the chair back sits
  /// against the bar, the arrow points away from the bar, out past the row
  /// of seats: 'near' seats sit above/left of the bar, so they look further
  /// up/left; 'far' seats sit below/right, so they look further down/right.
  String? get _facingArrow {
    if (!showFacingLabel) return null;
    final isHorizontal = table.orientation == TableOrientation.horizontal;
    switch (table.seatingSide) {
      case SeatingSide.both:
        return null;
      case SeatingSide.near:
        return isHorizontal ? '▼' : '▶';
      case SeatingSide.far:
        return isHorizontal ? '▲' : '◀';
    }
  }

  // A table is drawn like it'd look from above: a bar in the middle with
  // seats on its two long sides. The first half of the seats (rounding up)
  // sits on the near side, the rest on the far side — so seat 1 is always
  // diagonally opposite the last seat, matching how a host actually reads
  // a pankti/banana-leaf row. A one-sided table (against a wall or stage)
  // puts every seat on just that one side instead of splitting them.
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isHorizontal = table.orientation == TableOrientation.horizontal;

    final List<FloorSeat> nearSeats;
    final List<FloorSeat> farSeats;
    switch (table.seatingSide) {
      case SeatingSide.near:
        nearSeats = table.seats;
        farSeats = const [];
      case SeatingSide.far:
        nearSeats = const [];
        farSeats = table.seats;
      case SeatingSide.both:
        final nearCount = (table.seats.length / 2).ceil();
        nearSeats = table.seats.take(nearCount).toList();
        farSeats = table.seats.skip(nearCount).toList();
    }
    final crossCount = nearSeats.length > farSeats.length ? nearSeats.length : farSeats.length;
    final gap = 2.0;
    final crossExtent = crossCount == 0 ? seatSize : crossCount * seatSize + (crossCount - 1) * gap;

    Widget seatRun(List<FloorSeat> seats) {
      final boxes = [
        for (final seat in seats)
          _SeatBox(
            seat: seat,
            size: seatSize,
            selected: selectedSeatIds?.contains(seat.id) ?? false,
            tappable: _isTappable(seat),
            onTap: onToggleSeat == null ? null : () => onToggleSeat!(seat.id),
          ),
      ];
      return isHorizontal
          ? Row(mainAxisSize: MainAxisSize.min, children: _spaced(boxes, gap))
          : Column(mainAxisSize: MainAxisSize.min, children: _spaced(boxes, gap));
    }

    // The bar has to stay legible even when seatSize is small (a compact
    // preview can ask for seats as small as 12px) — below ~18px there's no
    // room left for "T12 ▼" without clipping, so the bar's thickness has a
    // floor independent of seatSize.
    final barThickness = seatSize * 0.6 < 18 ? 18.0 : seatSize * 0.6;
    final tableBar = Container(
      width: isHorizontal ? crossExtent : barThickness,
      height: isHorizontal ? barThickness : crossExtent,
      margin: EdgeInsets.symmetric(vertical: isHorizontal ? 4 : 0, horizontal: isHorizontal ? 0 : 4),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Text(
        ['T${table.tableNumber}', ?_facingArrow].join(' '),
        style: theme.textTheme.labelSmall,
        overflow: TextOverflow.visible,
        softWrap: false,
      ),
    );

    final children = [seatRun(nearSeats), tableBar, seatRun(farSeats)];

    return isHorizontal
        ? Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children)
        : Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: children);
  }

  bool _isTappable(FloorSeat seat) {
    if (onToggleSeat == null) return false;
    if (seat.status != FloorSeatStatus.available) return false;
    if (selectedSeatIds?.contains(seat.id) ?? false) return true;
    if (partySize == null) return true;
    return (selectedSeatIds?.length ?? 0) < partySize!;
  }

  List<Widget> _spaced(List<Widget> seats, double gap) => [
        for (final s in seats) ...[
          s,
          if (s != seats.last) SizedBox(width: gap, height: gap),
        ],
      ];
}

class _SeatBox extends StatelessWidget {
  const _SeatBox({
    required this.seat,
    required this.size,
    required this.selected,
    required this.tappable,
    this.onTap,
  });

  final FloorSeat seat;
  final double size;
  final bool selected;
  final bool tappable;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color color;
    if (selected) {
      color = scheme.primary;
    } else {
      switch (seat.status) {
        case FloorSeatStatus.available:
          color = scheme.surfaceContainerHighest;
        case FloorSeatStatus.booked:
        case FloorSeatStatus.occupied:
          color = scheme.errorContainer;
        case FloorSeatStatus.cleaning:
          color = scheme.surfaceContainerHigh;
      }
    }

    return Tooltip(
      message: 'Seat ${seat.seatNumber} · ${seat.status.name}',
      child: InkWell(
        onTap: tappable ? onTap : null,
        borderRadius: BorderRadius.circular(4),
        child: Opacity(
          opacity: onTap == null || tappable || selected ? 1 : 0.4,
          child: Container(
            width: size,
            height: size,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
            child: size >= 24
                ? Text('${seat.seatNumber}', style: TextStyle(fontSize: size * 0.45))
                : null,
          ),
        ),
      ),
    );
  }
}

/// Color key for FloorLayoutView — shown under the guest's seat picker so
/// "available vs. taken vs. selected" doesn't have to be inferred.
class FloorLegend extends StatelessWidget {
  const FloorLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 16,
      runSpacing: 4,
      children: [
        _LegendEntry(color: scheme.surfaceContainerHighest, label: 'Available'),
        _LegendEntry(color: scheme.primary, label: 'Selected'),
        _LegendEntry(color: scheme.errorContainer, label: 'Taken'),
        _LegendEntry(color: scheme.surfaceContainerHigh, label: 'Unavailable'),
      ],
    );
  }
}

class _LegendEntry extends StatelessWidget {
  const _LegendEntry({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
