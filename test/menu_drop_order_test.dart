import 'package:flutter_test/flutter_test.dart';

import 'package:catering_app/features/host/screens/host_menu_screen.dart';

/// Drop slots sit *between* rows, so for a section holding [a, b, c] the
/// index passed in is 0 (above a), 1 (a|b), 2 (b|c) or 3 (below c).
void main() {
  group('reordering within a section', () {
    test('dropping above itself lands at that slot', () {
      expect(
        dropOrder(siblings: ['a', 'b', 'c'], moved: 'c', targetIndex: 0),
        ['c', 'a', 'b'],
      );
    });

    test('dropping below itself accounts for its own removal', () {
      // 'a' into the slot between b and c. Naively inserting at 2 after
      // removing 'a' would put it after c; the shift correction is what
      // keeps it between them.
      expect(
        dropOrder(siblings: ['a', 'b', 'c'], moved: 'a', targetIndex: 2),
        ['b', 'a', 'c'],
      );
    });

    test('dropping at the end lands last', () {
      expect(
        dropOrder(siblings: ['a', 'b', 'c'], moved: 'a', targetIndex: 3),
        ['b', 'c', 'a'],
      );
    });

    test('dropping into either slot adjacent to itself is a no-op', () {
      for (final target in [1, 2]) {
        expect(
          dropOrder(siblings: ['a', 'b', 'c'], moved: 'b', targetIndex: target),
          ['a', 'b', 'c'],
          reason: 'slot $target neighbours b',
        );
      }
    });
  });

  group('moving in from another section', () {
    test('an arriving dish takes the slot as given, with no shift', () {
      expect(
        dropOrder(siblings: ['a', 'b', 'c'], moved: 'x', targetIndex: 2),
        ['a', 'b', 'x', 'c'],
      );
    });

    test('arriving at the top and the bottom', () {
      expect(dropOrder(siblings: ['a', 'b'], moved: 'x', targetIndex: 0), ['x', 'a', 'b']);
      expect(dropOrder(siblings: ['a', 'b'], moved: 'x', targetIndex: 2), ['a', 'b', 'x']);
    });

    test('arriving into an empty section', () {
      expect(dropOrder(siblings: [], moved: 'x', targetIndex: 0), ['x']);
    });
  });

  test('an out-of-range slot is clamped rather than throwing', () {
    expect(dropOrder(siblings: ['a', 'b'], moved: 'x', targetIndex: 99), ['a', 'b', 'x']);
    expect(dropOrder(siblings: ['a', 'b'], moved: 'x', targetIndex: -5), ['x', 'a', 'b']);
  });
}
