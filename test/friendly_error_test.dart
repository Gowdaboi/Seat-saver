import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:catering_app/core/errors.dart';

// QA found the raw PostgrestException — constraint name, key tuple, uuids —
// dumped verbatim into a snackbar when a guest was booked twice. None of that
// tells a caterer what to do, and it leaks schema shape to anyone watching
// the screen over their shoulder.
void main() {
  _unconfirmedTests();

  test('a repeat booking for the same guest reads as plain English', () {
    final error = PostgrestException(
      message: 'duplicate key value violates unique constraint '
          '"bookings_event_id_guest_id_key"',
      code: '23505',
      details: 'Key (event_id, guest_id)=(18e1dfec-83b7, ee89b95a-ba91) already exists.',
    );

    final message = friendlyError(error, fallback: 'Could not assign the seat(s).');

    expect(message, 'This guest already has a booking for this event.');
    // Nothing internal survives into what the host reads.
    expect(message, isNot(contains('constraint')));
    expect(message, isNot(contains('event_id')));
    expect(message, isNot(contains('18e1dfec')));
  });

  test('a repeat event name points at the name, not the index', () {
    final error = PostgrestException(
      message: 'duplicate key value violates unique constraint "events_caterer_name_uidx"',
      code: '23505',
      details: 'Key (caterer_id, lower(btrim(name)))=(455a025b, marriage) already exists.',
    );
    expect(
      friendlyError(error, fallback: 'nope'),
      'You already have an event with that name.',
    );
  });

  test('an unrecognised uniqueness clash still avoids leaking internals', () {
    final error = PostgrestException(
      message: 'duplicate key value violates unique constraint "some_future_uidx"',
      code: '23505',
      details: 'Key (a, b)=(1, 2) already exists.',
    );
    final message = friendlyError(error, fallback: 'nope');
    expect(message, isNot(contains('some_future_uidx')));
    expect(message, isNot(contains('Key (')));
  });

  test('a message our own RPC raised is passed through unchanged', () {
    // These are already written for people — see the raise statements in the
    // migrations — so translating them would lose real information.
    final error = PostgrestException(
      message: 'seat 3 is already taken for that round',
      code: 'P0001',
    );
    expect(friendlyError(error, fallback: 'nope'), 'seat 3 is already taken for that round');
  });

  test('a non-Postgrest failure falls back rather than showing a stack trace', () {
    expect(
      friendlyError(StateError('SocketException: connection refused'), fallback: 'Could not save.'),
      'Could not save.',
    );
  });

  test('a Postgrest error with an empty message falls back', () {
    expect(
      friendlyError(PostgrestException(message: '   ', code: '42P01'), fallback: 'Could not save.'),
      'Could not save.',
    );
  });
}

// The resend affordance only appears when this returns true, so a Supabase
// release that changes the code or the wording would quietly remove the one
// recovery path for an unconfirmed account.
void _unconfirmedTests() {
  group('isEmailNotConfirmed', () {
    test('matches the documented error code', () {
      expect(
        isEmailNotConfirmed(
          AuthException('Email not confirmed', statusCode: '400', code: 'email_not_confirmed'),
        ),
        isTrue,
      );
    });

    test('falls back to the message when no code is sent', () {
      expect(isEmailNotConfirmed(AuthException('Email not confirmed')), isTrue);
    });

    test('is case-insensitive about the message', () {
      expect(isEmailNotConfirmed(AuthException('EMAIL NOT CONFIRMED')), isTrue);
    });

    test('does not fire on a wrong password', () {
      expect(
        isEmailNotConfirmed(
          AuthException('Invalid login credentials', code: 'invalid_credentials'),
        ),
        isFalse,
      );
    });

    test('does not fire on a non-auth error', () {
      expect(isEmailNotConfirmed(StateError('socket closed')), isFalse);
    });
  });
}
