import 'package:go_router/go_router.dart';

import 'supabase_client.dart';
import '../features/guest/screens/guest_booking_confirmation_screen.dart';
import '../features/guest/screens/guest_call_host_screen.dart';
import '../features/guest/screens/guest_cancel_booking_screen.dart';
import '../features/guest/screens/guest_event_entry_screen.dart';
import '../features/guest/screens/guest_floor_menu_screen.dart';
import '../features/guest/screens/guest_phone_otp_screen.dart';
import '../features/guest/screens/guest_reassignment_offer_screen.dart';
import '../features/guest/screens/guest_seat_picker_screen.dart';
import '../features/host/screens/host_call_requests_screen.dart';
import '../features/host/screens/host_create_event_screen.dart';
import '../features/host/screens/host_dashboard_screen.dart';
import '../features/host/screens/host_event_qr_screen.dart';
import '../features/host/screens/host_feedback_form_screen.dart';
import '../features/host/screens/host_floor_design_screen.dart';
import '../features/host/screens/host_forgot_password_screen.dart';
import '../features/host/screens/host_login_screen.dart';
import '../features/host/screens/host_menu_screen.dart';
import '../features/host/screens/host_noshow_review_screen.dart';
import '../features/host/screens/host_past_event_detail_screen.dart';
import '../features/host/screens/host_past_events_screen.dart';
import '../features/host/screens/host_reset_password_screen.dart';
import '../features/host/screens/host_rounds_screen.dart';
import '../features/host/screens/host_seat_management_screen.dart';
import '../features/host/screens/host_seat_scan_screen.dart';
import '../features/host/screens/host_signup_screen.dart';
import '../features/shared/role_picker_screen.dart';

/// Guests never navigate here manually — every real guest arrives via
/// /e/:eventId from a QR code the host generates (HostEventQrScreen).
/// Everything under /e carries the event id forward through the whole
/// guest flow, since the guest screens have no other way to know which
/// event they're booking into.
/// Whether the stored session belongs to a *host* rather than a guest.
///
/// Both roles are real auth.users, so `currentSession != null` alone can't
/// tell them apart, and bouncing a logged-in guest to the host dashboard
/// would be worse than not redirecting at all. Hosts sign in with
/// email/password and guests with phone OTP, so the presence of an email is
/// the one discriminator available without an async round-trip — and a
/// redirect callback has to answer synchronously.
bool _hostSessionExists() {
  final user = supabase.auth.currentUser;
  if (user == null) return false;
  return (user.email ?? '').isNotEmpty;
}

final appRouter = GoRouter(
  initialLocation: '/',
  // Reloading the page used to drop a signed-in host back on the role picker,
  // which read as "it logged me out". The session was never actually lost —
  // supabase_flutter persists it to local storage — there was simply nothing
  // routing an existing session anywhere. Hosts refresh mid-event, so this
  // matters more than it sounds.
  redirect: (context, state) {
    final path = state.uri.path;
    // Only the two entry points bounce. Everything else is left alone: the
    // whole guest flow, the password-recovery screen (which runs on a real
    // session and must not be redirected away from), and the /c/:token
    // cancel link, which is deliberately reachable signed out.
    if (path != '/' && path != '/host/login') return null;
    return _hostSessionExists() ? '/host/dashboard' : null;
  },
  routes: [
    GoRoute(path: '/', builder: (context, state) => const RolePickerScreen()),

    GoRoute(path: '/host/login', builder: (context, state) => const HostLoginScreen()),
    GoRoute(path: '/host/signup', builder: (context, state) => const HostSignUpScreen()),
    GoRoute(path: '/host/forgot-password', builder: (context, state) => const HostForgotPasswordScreen()),
    GoRoute(path: '/host/reset-password', builder: (context, state) => const HostResetPasswordScreen()),
    GoRoute(path: '/host/dashboard', builder: (context, state) => const HostDashboardScreen()),
    GoRoute(path: '/host/events/create', builder: (context, state) => const HostCreateEventScreen()),
    GoRoute(path: '/host/events/qr', builder: (context, state) => const HostEventQrScreen()),
    GoRoute(path: '/host/events/past', builder: (context, state) => const HostPastEventsScreen()),
    GoRoute(
      path: '/host/events/past/:eventId',
      builder: (context, state) => HostPastEventDetailScreen(eventId: state.pathParameters['eventId']!),
    ),
    GoRoute(path: '/host/floor', builder: (context, state) => const HostFloorDesignScreen()),
    GoRoute(path: '/host/seats', builder: (context, state) => const HostSeatManagementScreen()),
    GoRoute(path: '/host/menu', builder: (context, state) => const HostMenuScreen()),
    GoRoute(path: '/host/rounds', builder: (context, state) => const HostRoundsScreen()),
    GoRoute(path: '/host/noshow', builder: (context, state) => const HostNoShowReviewScreen()),
    GoRoute(path: '/host/scan', builder: (context, state) => const HostSeatScanScreen()),
    GoRoute(path: '/host/calls', builder: (context, state) => const HostCallRequestsScreen()),
    GoRoute(path: '/host/feedback', builder: (context, state) => const HostFeedbackFormScreen()),

    GoRoute(
      path: '/e/:eventId',
      builder: (context, state) => GuestEventEntryScreen(eventId: state.pathParameters['eventId']!),
    ),
    GoRoute(
      path: '/e/:eventId/otp',
      builder: (context, state) => GuestPhoneOtpScreen(eventId: state.pathParameters['eventId']!),
    ),
    GoRoute(
      path: '/e/:eventId/floor',
      builder: (context, state) => GuestFloorMenuScreen(eventId: state.pathParameters['eventId']!),
    ),
    GoRoute(
      path: '/e/:eventId/seats',
      builder: (context, state) => GuestSeatPickerScreen(
        eventId: state.pathParameters['eventId']!,
        sectionId: state.uri.queryParameters['section']!,
      ),
    ),
    GoRoute(
      path: '/e/:eventId/confirmation',
      builder: (context, state) => GuestBookingConfirmationScreen(
        bookingId: state.uri.queryParameters['booking']!,
      ),
    ),
    GoRoute(
      path: '/e/:eventId/offer',
      builder: (context, state) => const GuestReassignmentOfferScreen(),
    ),
    GoRoute(
      path: '/e/:eventId/call-host',
      builder: (context, state) => GuestCallHostScreen(eventId: state.pathParameters['eventId']!),
    ),

    // Not under /e/:eventId, and not behind a login, because this is the
    // link inside a round-reminder SMS: the token already identifies one
    // booking (and through it the event), and the guest reading the message
    // may never have signed in on that phone. Kept short so it survives
    // being pasted into a 160-character message.
    GoRoute(
      path: '/c/:token',
      builder: (context, state) =>
          GuestCancelBookingScreen(token: state.pathParameters['token']!),
    ),
  ],
);
