import 'dart:async';

import 'package:maia_api_client/maia_api_client.dart';

const friendlyFailure = 'Something went wrong. Try again.';

/// The line to show. API errors keep their short message and reference.
/// Anything else stays off the screen; the raw text is reported instead.
String shownFault(Object error) {
  if (error is MaiaApiException) return error.shown;
  return friendlyFailure;
}

/// Saves a client-side failure. API errors are already stored on the server.
void rememberFault(MaiaApiClient api, String action, Object error) {
  if (error is MaiaApiException) return;
  unawaited(api.reportFault(action: action, detail: '$error'));
}
