import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:catering_app/features/shared/widgets/floor_layout.dart';

/// Builds tables positioned the way configure_section_layout() positions them
/// (row-major over ceil(count / rows) columns), so these tests exercise the
/// same geometry the migration produces.
List<FloorTable> _grid({
  required int tableCount,
  required int seatsPerTable,
  required int rows,
  TableOrientation orientation = TableOrientation.horizontal,
}) {
  final cols = (tableCount / rows).ceil();
  return [
    for (var i = 0; i < tableCount; i++)
      FloorTable(
        id: 't$i',
        tableNumber: i + 1,
        gridRow: i ~/ cols,
        gridCol: i % cols,
        orientation: orientation,
        seats: [
          for (var n = 1; n <= seatsPerTable; n++)
            FloorSeat(id: 't$i-s$n', seatNumber: n, status: FloorSeatStatus.available),
        ],
      ),
  ];
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('every table in the layout is drawn', (tester) async {
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: _grid(
      tableCount: 8,
      seatsPerTable: 6,
      rows: 2,
    ))));

    for (var n = 1; n <= 8; n++) {
      expect(find.text('T$n'), findsOneWidget);
    }
  });

  testWidgets('tables are grouped onto the rows the host asked for', (tester) async {
    // 8 tables over 2 rows => 4 per row, so T1 and T5 start the two rows and
    // must sit at the same x but different y.
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: _grid(
      tableCount: 8,
      seatsPerTable: 6,
      rows: 2,
    ))));

    final first = tester.getTopLeft(find.text('T1'));
    final second = tester.getTopLeft(find.text('T5'));
    expect(second.dy, greaterThan(first.dy));
    expect(second.dx, moreOrLessEquals(first.dx, epsilon: 0.5));

    // T2 is the next table along the first row: same y, further right.
    final sameRow = tester.getTopLeft(find.text('T2'));
    expect(sameRow.dy, moreOrLessEquals(first.dy, epsilon: 0.5));
    expect(sameRow.dx, greaterThan(first.dx));
  });

  testWidgets('orientation decides which sides the seats sit on', (tester) async {
    // Horizontal: seat 1 above the table, seat 4 (start of the far side) below.
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: _grid(
      tableCount: 1,
      seatsPerTable: 6,
      rows: 1,
    ))));
    var near = tester.getCenter(find.text('1'));
    var far = tester.getCenter(find.text('4'));
    expect(far.dy, greaterThan(near.dy));
    expect(far.dx, moreOrLessEquals(near.dx, epsilon: 0.5));

    // Vertical: the same two seats are now left and right of the table.
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: _grid(
      tableCount: 1,
      seatsPerTable: 6,
      rows: 1,
      orientation: TableOrientation.vertical,
    ))));
    near = tester.getCenter(find.text('1'));
    far = tester.getCenter(find.text('4'));
    expect(far.dx, greaterThan(near.dx));
    expect(far.dy, moreOrLessEquals(near.dy, epsilon: 0.5));
  });

  testWidgets('an odd seat count puts the extra seat on the near side', (tester) async {
    // 5 seats => 3 near (1,2,3), 2 far (4,5).
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: _grid(
      tableCount: 1,
      seatsPerTable: 5,
      rows: 1,
    ))));

    final nearY = tester.getCenter(find.text('1')).dy;
    for (final n in ['2', '3']) {
      expect(tester.getCenter(find.text(n)).dy, moreOrLessEquals(nearY, epsilon: 0.5));
    }
    for (final n in ['4', '5']) {
      expect(tester.getCenter(find.text(n)).dy, greaterThan(nearY));
    }
  });

  testWidgets('a one-sided table puts every seat on that one side', (tester) async {
    final tables = [
      FloorTable(
        id: 't0',
        tableNumber: 1,
        seatingSide: SeatingSide.near,
        seats: const [
          FloorSeat(id: 'a', seatNumber: 1, status: FloorSeatStatus.available),
          FloorSeat(id: 'b', seatNumber: 2, status: FloorSeatStatus.available),
          FloorSeat(id: 'c', seatNumber: 3, status: FloorSeatStatus.available),
          FloorSeat(id: 'd', seatNumber: 4, status: FloorSeatStatus.available),
        ],
      ),
    ];
    await tester.pumpWidget(_wrap(FloorLayoutView(tables: tables)));

    // All four seats land on the same side (same y for a horizontal table),
    // not split 2-and-2 the way a both-sided table would be.
    final firstY = tester.getCenter(find.text('1')).dy;
    for (final n in ['2', '3', '4']) {
      expect(tester.getCenter(find.text(n)).dy, moreOrLessEquals(firstY, epsilon: 0.5));
    }
  });

  testWidgets('selection is capped at the party size', (tester) async {
    final selected = <String>{};
    final tables = _grid(tableCount: 1, seatsPerTable: 6, rows: 1);

    await tester.pumpWidget(_wrap(StatefulBuilder(
      builder: (context, setState) => FloorLayoutView(
        tables: tables,
        selectedSeatIds: selected,
        partySize: 2,
        onToggleSeat: (id) => setState(() {
          selected.contains(id) ? selected.remove(id) : selected.add(id);
        }),
      ),
    )));

    await tester.tap(find.text('1'));
    await tester.pump();
    await tester.tap(find.text('2'));
    await tester.pump();
    expect(selected, hasLength(2));

    // Third tap must not take — the party is already fully seated.
    await tester.tap(find.text('3'));
    await tester.pump();
    expect(selected, hasLength(2));

    // Deselecting still works, and frees the slot back up.
    await tester.tap(find.text('1'));
    await tester.pump();
    expect(selected, hasLength(1));
  });

  testWidgets('taken seats are not selectable', (tester) async {
    final selected = <String>{};
    final tables = [
      FloorTable(
        id: 't0',
        tableNumber: 1,
        seats: const [
          FloorSeat(id: 'a', seatNumber: 1, status: FloorSeatStatus.booked),
          FloorSeat(id: 'b', seatNumber: 2, status: FloorSeatStatus.available),
        ],
      ),
    ];

    await tester.pumpWidget(_wrap(FloorLayoutView(
      tables: tables,
      selectedSeatIds: selected,
      partySize: 2,
      onToggleSeat: selected.add,
    )));

    await tester.tap(find.text('1'));
    await tester.pump();
    expect(selected, isEmpty);

    await tester.tap(find.text('2'));
    await tester.pump();
    expect(selected, {'b'});
  });

  testWidgets('the host preview is read-only', (tester) async {
    await tester.pumpWidget(_wrap(FloorLayoutView(
      tables: _grid(tableCount: 2, seatsPerTable: 4, rows: 1),
      seatSize: 18,
      scrollVertically: false,
    )));

    // Below the 24px threshold seat numbers are dropped, but the tables
    // themselves still label the floor.
    expect(find.text('1'), findsNothing);
    expect(find.text('T1'), findsOneWidget);
    expect(find.text('T2'), findsOneWidget);
  });
}
