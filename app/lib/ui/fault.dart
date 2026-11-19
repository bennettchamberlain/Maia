import 'dart:async';

import 'package:maie_api_client/maie_api_client.dart';

const friendlyFailure = 'Something went wrong. Try again.';

/// The line to show. API errors keep their short message and reference.
/// Anything else stays off the screen; the raw text is reported instead.
String shownFault(Object error) {
  if (error is MaieApiException) return error.shown;
  return friendlyFailure;
}

/// Saves a client-side failure. API errors are already stored on the server.
void rememberFault(MaieApiClient api, String action, Object error) {
  if (error is MaieApiException) return;
  unawaited(api.reportFault(action: action, detail: '$error'));
}
