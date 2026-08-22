import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:catering_app/features/host/screens/host_login_screen.dart';
import 'package:catering_app/features/host/screens/host_signup_screen.dart';
import 'package:catering_app/features/shared/role_picker_screen.dart';

// Host-flow screens don't fetch anything in initState, so they're safe to
// exercise directly with tester.tap() against the real GoRouter config
// (mirrors lib/core/router.dart) without Supabase initialized. Guest
// screens now fetch real event/session data as soon as they mount (QR
// landing, seat picker, etc.), which needs a reachable backend — that
// behavior is covered by the SQL-level RLS/RPC tests instead; this test
// covers the router's own path-parameter wiring using lightweight stub
// screens, which is the part that's actually this file's own logic.
GoRouter _hostTestRouter() => GoRouter(
      initialLocation: '/',
      routes: [
        GoRoute(path: '/', builder: (context, state) => const RolePickerScreen()),
        GoRoute(path: '/host/login', builder: (context, state) => const HostLoginScreen()),
        GoRoute(path: '/host/signup', builder: (context, state) => const HostSignUpScreen()),
      ],
    );

GoRouter _eventRouteTestRouter() => GoRouter(
      initialLocation: '/e/abc-123',
      routes: [
        GoRoute(
          path: '/e/:eventId',
          builder: (context, state) => _EventIdProbe(
            label: 'entry',
            eventId: state.pathParameters['eventId'],
          ),
        ),
        GoRoute(
          path: '/e/:eventId/seats',
          builder: (context, state) => _EventIdProbe(
            label: 'seats',
            eventId: state.pathParameters['eventId'],
            extra: state.uri.queryParameters['section'],
          ),
        ),
      ],
    );

/// The cancel link an SMS carries. Tokens are base64url, so they contain
/// '-' and '_' — characters a path parameter has to hand back untouched or
/// the lookup silently misses and the guest is told their link is invalid.
GoRouter _cancelRouteTestRouter(String initial) => GoRouter(
      initialLocation: initial,
      routes: [
        GoRoute(
          path: '/c/:token',
          builder: (context, state) => Scaffold(
            body: Center(child: Text('token:${state.pathParameters['token']}')),
          ),
        ),
      ],
    );

class _EventIdProbe extends StatelessWidget {
  const _EventIdProbe({required this.label, required this.eventId, this.extra});
  final String label;
  final String? eventId;
  final String? extra;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('screen:$label'),
            Text('eventId:$eventId'),
            if (extra != null) Text('extra:$extra'),
            ElevatedButton(
              onPressed: () => context.push('/e/$eventId/seats?section=sec-1'),
              child: const Text('go to seats'),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('host flow: role picker -> login -> signup', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _hostTestRouter()));

    await tester.tap(find.text("I'm hosting an event"));
    await tester.pumpAndSettle();

    expect(find.text('Host log in'), findsOneWidget);
    await tester.tap(find.text('New caterer? Sign up'));
    await tester.pumpAndSettle();

    expect(find.text('Caterer sign up'), findsOneWidget);
  });

  testWidgets('event routes: eventId and query params thread through nested routes', (tester) async {
    await tester.pumpWidget(MaterialApp.router(routerConfig: _eventRouteTestRouter()));

    expect(find.text('screen:entry'), findsOneWidget);
    expect(find.text('eventId:abc-123'), findsOneWidget);

    await tester.tap(find.text('go to seats'));
    await tester.pumpAndSettle();

    expect(find.text('screen:seats'), findsOneWidget);
    expect(find.text('eventId:abc-123'), findsOneWidget);
    expect(find.text('extra:sec-1'), findsOneWidget);
  });

  testWidgets('cancel route: a base64url token survives path parsing intact',
      (tester) async {
    // Shape of a real cancel_token: 32 chars from [A-Za-z0-9_-].
    const token = 'nPWJrT4YtN-q8zss4w243Kis_5D6ae7M';
    await tester.pumpWidget(
      MaterialApp.router(routerConfig: _cancelRouteTestRouter('/c/$token')),
    );

    expect(find.text('token:$token'), findsOneWidget);
  });

  testWidgets('cancel route: a percent-encoded token is decoded once',
      (tester) async {
    // The sender percent-encodes the token into the URL, so what arrives may
    // be escaped; what reaches the RPC has to be the original string.
    const token = 'abc-_123';
    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: _cancelRouteTestRouter('/c/${Uri.encodeComponent(token)}'),
      ),
    );

    expect(find.text('token:$token'), findsOneWidget);
  });
}
