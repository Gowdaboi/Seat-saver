/// Where this copy of the app actually lives, and what Supabase should send
/// people back to.
///
/// Every emailed link — signup confirmation, password recovery — has to point
/// at the deployment the person is using. Two ways that went wrong:
///
///   * `signUp()` passed no redirect at all, so Supabase fell back to the
///     project's Site URL. That is one fixed value, and it was
///     `http://localhost:8765` — so every confirmation email sent to anyone
///     but the developer linked to a machine they don't have. (Issue #1.)
///   * The recovery link used `Uri.base.origin`, which is scheme + host only.
///     On GitHub Pages the app is served from `/Seat-saver/`, so the origin
///     alone pointed at the account root and 404'd.
///
/// Deriving both from the running page means a build served from localhost
/// mails localhost links and a build served from Pages mails Pages links,
/// with nothing to keep in sync by hand.
///
/// The `…From(Uri)` variants exist so this is testable: `Uri.base` under the
/// test runner is a file path, and URL assembly that only breaks in one
/// deployment is precisely what wants a test.
library;

/// Absolute URL of the app root, always ending in `/`.
///
/// Path is kept and query/fragment dropped: the current location carries the
/// hash route, and may also carry error parameters from a failed link.
String appRootUrlFrom(Uri base) {
  final root = Uri(
    scheme: base.scheme,
    host: base.host,
    port: base.hasPort ? base.port : null,
    path: base.path,
  ).toString();
  return root.endsWith('/') ? root : '$root/';
}

/// Absolute URL for a hash route, e.g. `/host/login` →
/// `https://gowdaboi.github.io/Seat-saver/#/host/login`.
String appUrlFrom(Uri base, String hashRoute) {
  final route = hashRoute.startsWith('/') ? hashRoute : '/$hashRoute';
  return '${appRootUrlFrom(base)}#$route';
}

/// The human-readable reason a Supabase auth link failed, or null.
///
/// A dead confirmation link drops the person on the app root with the reason
/// in the URL and nothing on screen to explain it — which is what the bug
/// report was describing: a link that "goes nowhere". Supabase puts these in
/// the fragment, and sometimes the query as well, so both are read.
String? authErrorFrom(Uri base) {
  String? pick(Map<String, String> params) {
    final description = params['error_description'];
    if (description != null && description.trim().isNotEmpty) {
      // These arrive '+'-encoded for spaces even inside a fragment, where
      // Uri's own decoding leaves them alone.
      return description.replaceAll('+', ' ');
    }
    final code = params['error'];
    return (code != null && code.trim().isNotEmpty) ? code : null;
  }

  final fromQuery = pick(base.queryParameters);
  if (fromQuery != null) return fromQuery;

  // The fragment holds the hash route as well as any error parameters, so
  // drop everything before the first '&' when a route is present.
  final fragment = base.fragment;
  if (!fragment.contains('error')) return null;
  final queryPart =
      fragment.contains('&') ? fragment.substring(fragment.indexOf('&') + 1) : fragment;
  try {
    return pick(Uri.splitQueryString(queryPart));
  } catch (_) {
    return null;
  }
}

/// Absolute URL of the app root, always ending in `/`.
String appRootUrl() => appRootUrlFrom(Uri.base);

/// Absolute URL for a hash route on this deployment.
///
/// Supabase checks these against the project's Redirect URLs allow-list, so a
/// new deployment origin has to be added there before its links will work.
String appUrl(String hashRoute) => appUrlFrom(Uri.base, hashRoute);

/// The reason a Supabase auth link failed, from the current page URL.
String? authErrorFromUrl() => authErrorFrom(Uri.base);
