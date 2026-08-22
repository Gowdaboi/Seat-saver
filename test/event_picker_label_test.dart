import 'package:flutter_test/flutter_test.dart';

import 'package:catering_app/features/host/widgets/event_picker.dart';

// The QA pass found two events both showing as "Marriage" in the picker with
// nothing to tell them apart. 0016 makes the name unique per caterer, but the
// label still has to carry the date and venue — that is what a host actually
// recognises an event by, and choosing wrong means working on the wrong night.
void main() {
  test('renders name, date and venue', () {
    expect(
      eventPickerLabel({
        'name': 'Sangeet',
        'date': '2026-12-01',
        'venue_name': 'Grand Palace',
      }),
      'Sangeet · 1 Dec 2026 · Grand Palace',
    );
  });

  test('two same-named events on different dates are distinguishable', () {
    final a = eventPickerLabel({
      'name': 'Marriage',
      'date': '2026-12-01',
      'venue_name': 'Hall A',
    });
    final b = eventPickerLabel({
      'name': 'Marriage',
      'date': '2026-12-02',
      'venue_name': 'Hall B',
    });
    expect(a, isNot(b));
  });

  test('a missing venue leaves no dangling separator', () {
    expect(
      eventPickerLabel({'name': 'Sangeet', 'date': '2026-12-01', 'venue_name': null}),
      'Sangeet · 1 Dec 2026',
    );
  });

  test('an empty venue string is dropped, not rendered as a gap', () {
    expect(
      eventPickerLabel({'name': 'Sangeet', 'date': '2026-12-01', 'venue_name': '   '}),
      'Sangeet · 1 Dec 2026',
    );
  });

  test('an unparseable date falls back to its raw text rather than vanishing', () {
    expect(
      eventPickerLabel({'name': 'Sangeet', 'date': 'not-a-date', 'venue_name': 'Hall A'}),
      'Sangeet · not-a-date · Hall A',
    );
  });

  test('single-digit and December dates format without padding or overflow', () {
    expect(eventPickerLabel({'name': 'E', 'date': '2026-01-09'}), 'E · 9 Jan 2026');
    expect(eventPickerLabel({'name': 'E', 'date': '2026-12-31'}), 'E · 31 Dec 2026');
  });
}
