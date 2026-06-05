/// Patchwing Web Console URLs.
class PatchwingWebConsole {
  /// Returns a [Uri] for the Patchwing Web Console.
  static Uri uri(String path) {
    return Uri.parse('https://console.patchwing.net/$path');
  }

  /// Returns a [Uri] for the Patchwing Web Console login page.
  static Uri appReleaseUri(String appId, int releaseId) {
    return PatchwingWebConsole.uri('apps/$appId/releases/$releaseId');
  }
}
