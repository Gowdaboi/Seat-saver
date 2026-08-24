import 'package:flutter_test/flutter_test.dart';

import 'package:catering_app/core/app_url.dart';

// Issue #1: confirmation emails linked to http://localhost:8765, because
// signUp() passed no redirect and Supabase fell back to the project's single
// Site URL. The fix derives the link from the running page — so these tests
// pin the two deployments that actually exist, including the base path that
// the previous `Uri.base.origin` approach silently dropped.
void main() {
  group('link building', () {
    test('GitHub Pages keeps the base path', () {
      final base = Uri.parse('https://gowdaboi.github.io/Seat-saver/#/host/signup');
      expect(
        appUrlFrom(base, '/host/login'),
        'https://gowdaboi.github.io/Seat-saver/#/host/login',
      );
    });

    test('localhost keeps its port', () {
      final base = Uri.parse('http://localhost:8765/#/host/signup');
      expect(appUrlFrom(base, '/host/login'), 'http://localhost:8765/#/host/login');
    });

    test('the old origin-only approach is what this replaces', () {
      // Kept as an explicit contrast: origin alone loses /Seat-saver/, which
      // is why recovery links 404'd on Pages.
      final base = Uri.parse('https://gowdaboi.github.io/Seat-saver/#/host/forgot');
      expect(appUrlFrom(base, '/host/reset-password'), isNot(startsWith('${base.origin}/#')));
      expect(appUrlFrom(base, '/host/reset-password'), contains('/Seat-saver/'));
    });

    test('a root path is not doubled up', () {
      expect(appRootUrlFrom(Uri.parse('http://localhost:8765/')), 'http://localhost:8765/');
      expect(appRootUrlFrom(Uri.parse('http://localhost:8765')), 'http://localhost:8765/');
    });

    test('a missing base path still gets its trailing slash', () {
      expect(
        appUrlFrom(Uri.parse('https://example.com/app'), '/host/login'),
        'https://example.com/app/#/host/login',
      );
    });

    test('a route without a leading slash is normalised', () {
      expect(
        appUrlFrom(Uri.parse('http://localhost:8765/'), 'host/login'),
        'http://localhost:8765/#/host/login',
      );
    });

    test('error parameters on the current page do not leak into the link', () {
      final base = Uri.parse(
        'http://localhost:8765/?error=access_denied&error_code=otp_expired#/host/login',
      );
      expect(appUrlFrom(base, '/host/login'), 'http://localhost:8765/#/host/login');
    });
  });

  group('reading the failure reason', () {
    // The exact URL from the bug report.
    final reported = Uri.parse(
      'http://localhost:8765/?error=access_denied&error_code=otp_expired'
      '&error_description=Email+link+is+invalid+or+has+expired'
      '#error=access_denied&error_code=otp_expired'
      '&error_description=Email+link+is+invalid+or+has+expired&sb=',
    );

    test('reads the reported expired link', () {
      expect(authErrorFrom(reported), 'Email link is invalid or has expired');
    });

    test('reads it from the fragment alone', () {
      final base = Uri.parse(
        'https://gowdaboi.github.io/Seat-saver/'
        '#/&error=access_denied&error_description=Email+link+is+invalid+or+has+expired',
      );
      expect(authErrorFrom(base), 'Email link is invalid or has expired');
    });

    test('falls back to the bare error code when no description is given', () {
      expect(
        authErrorFrom(Uri.parse('http://localhost:8765/?error=access_denied')),
        'access_denied',
      );
    });

    test('a normal page reports nothing', () {
      expect(authErrorFrom(Uri.parse('http://localhost:8765/#/host/login')), isNull);
      expect(authErrorFrom(Uri.parse('https://gowdaboi.github.io/Seat-saver/')), isNull);
    });

    test('an empty description is not treated as a reason', () {
      expect(authErrorFrom(Uri.parse('http://localhost:8765/?error_description=')), isNull);
    });

    test('a cancel link is never mistaken for an error', () {
      final cancel =
          Uri.parse('https://gowdaboi.github.io/Seat-saver/#/c/nPWJrT4YtN-q8zss4w243Kis_5D6ae7M');
      expect(authErrorFrom(cancel), isNull);
    });
  });
}
