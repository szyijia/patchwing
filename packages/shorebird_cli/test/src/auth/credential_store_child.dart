// Real subprocess probe. Never prints credential values.
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:shorebird_cli/src/auth/credential_store.dart';

Future<void> main(List<String> args) async {
  final store = CredentialStore(args[0]);
  if (args.length == 1) {
    await store.locked(() async {
      stdout.writeln('LOCKED');
      await stdin.first;
    });
    return;
  }
  final stale = store.read();
  stdout.writeln('READY');
  await stdin.first;
  final resolved = await store.resolve(stale, (credentials) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse(args[1]));
      request.write(credentials.refreshToken);
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != 200) throw StateError('Refresh rejected');
      return AccessCredentials.fromJson(
        jsonDecode(body) as Map<String, dynamic>,
      );
    } finally {
      client.close(force: true);
    }
  });
  if (resolved.refreshToken != 'rotated-test-refresh') {
    throw StateError('Did not observe committed rotation');
  }
  stdout.writeln('RESOLVED');
}
