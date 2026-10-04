import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shorebird_cli/src/auth/auth.dart';
import 'package:shorebird_cli/src/auth/credential_store.dart';
import 'package:test/test.dart';

AccessCredentials fixture({bool expired = false, String user = '1'}) {
  final payload = base64Url
      .encode(
        utf8.encode(
          jsonEncode({
            'iss': 'https://auth.patchwing.net',
            'sub': user,
            'sid': 'test-session',
          }),
        ),
      )
      .replaceAll('=', '');
  return AccessCredentials(
    AccessToken(
      'Bearer',
      'test-access',
      DateTime.now().toUtc().add(
        expired ? const Duration(minutes: -1) : const Duration(minutes: 15),
      ),
    ),
    expired ? 'original-test-refresh' : 'rotated-test-refresh',
    [],
    idToken: 'e30.$payload.test-signature',
  );
}

Future<List<String>> childArguments(
  String credentials, [
  String? endpoint,
]) async {
  final source = await Isolate.resolvePackageUri(
    Uri.parse('package:shorebird_cli/src/auth/credential_store.dart'),
  );
  final package = File.fromUri(source!).parent.parent.parent.parent;
  return [
    '--packages=${package.parent.parent.path}/.dart_tool/package_config.json',
    '${package.path}/test/src/auth/credential_store_child.dart',
    credentials,
    if (endpoint != null) endpoint,
  ];
}

void main() {
  late Directory directory;
  late CredentialStore store;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('pw-auth-sync-test-');
    store = CredentialStore('${directory.path}/credentials.json')
      ..write(fixture(expired: true));
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('concurrent clients reread after one rotation', () async {
    final stale = store.read();
    var exchanges = 0;
    final results = await Future.wait(
      List.generate(
        20,
        (_) => CredentialStore(store.path).resolve(stale, (_) async {
          exchanges++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return fixture();
        }),
      ),
    );
    expect(exchanges, 1);
    expect(
      results.every((result) => result.refreshToken == 'rotated-test-refresh'),
      isTrue,
    );
    expect(store.read().refreshToken, 'rotated-test-refresh');
  });

  test('missing credentials do not resurrect a logged-out session', () async {
    final stale = store.read();
    File(store.path).deleteSync();
    await expectLater(
      store.resolve(stale, (_) async => fixture()),
      throwsStateError,
    );
    expect(File(store.path).existsSync(), isFalse);
  });

  test('HTTP client rereads credentials before attempting refresh', () async {
    final stale = store.read();
    store.write(fixture());
    var requests = 0;
    final client = AuthenticatedClient.credentials(
      credentials: stale,
      credentialStore: store,
      authServiceUri: Uri.parse('https://auth.patchwing.net'),
      httpClient: MockClient((request) async {
        requests++;
        expect(request.method, 'GET');
        expect(request.headers['Authorization'], 'Bearer ${fixture().idToken}');
        return http.Response('ok', 200);
      }),
    );
    expect(
      (await client.get(Uri.parse('https://example.test/api'))).statusCode,
      200,
    );
    expect(requests, 1);
    client.close();
  });

  test(
    'logout waits for refresh and later commands cannot resurrect it',
    () async {
      final stale = store.read();
      final refreshing = Completer<void>();
      final finishRefresh = Completer<void>();
      final resolved = store.resolve(stale, (_) async {
        refreshing.complete();
        await finishRefresh.future;
        return fixture();
      });
      await refreshing.future;
      final logout = CredentialStore(store.path).locked(() async {
        expect(store.read().refreshToken, 'rotated-test-refresh');
        File(store.path).deleteSync();
      });
      finishRefresh.complete();
      await resolved;
      await logout;
      await expectLater(
        store.resolve(stale, (_) async => fixture()),
        throwsStateError,
      );
      expect(File(store.path).existsSync(), isFalse);
    },
  );

  test('changed identity fails instead of switching users', () async {
    final stale = store.read();
    store.write(fixture(user: '2'));
    await expectLater(
      store.resolve(stale, (_) async => fixture()),
      throwsStateError,
    );
  });

  test('corruption and refresh rejection remain visible', () async {
    final stale = store.read();
    await expectLater(
      store.resolve(stale, (_) async => throw StateError('rejected')),
      throwsStateError,
    );
    expect(store.read().refreshToken, stale.refreshToken);
    File(store.path).writeAsStringSync('{broken');
    await expectLater(
      store.resolve(stale, (_) async => fixture()),
      throwsFormatException,
    );
  });

  test(
    'six actual processes exchange a single-use refresh only once',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var exchanges = 0;
      final subscription = server.listen((request) async {
        final raw = await utf8.decoder.bind(request).join();
        exchanges++;
        if (raw != 'original-test-refresh' || exchanges > 1) {
          request.response.statusCode = 400;
          request.response.write('invalid_grant');
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          request.response.write(jsonEncode(fixture().toJson()));
        }
        await request.response.close();
      });
      final processes = <Process>[];
      try {
        final lines = <StreamIterator<String>>[];
        final errors = <Future<String>>[];
        for (var i = 0; i < 6; i++) {
          final child = await Process.start(
            Platform.resolvedExecutable,
            await childArguments(
              store.path,
              'http://127.0.0.1:${server.port}/token',
            ),
          );
          processes.add(child);
          errors.add(utf8.decoder.bind(child.stderr).join());
          final iterator = StreamIterator(
            utf8.decoder.bind(child.stdout).transform(const LineSplitter()),
          );
          lines.add(iterator);
          expect(
            await iterator.moveNext().timeout(const Duration(seconds: 30)),
            isTrue,
          );
          expect(iterator.current, 'READY');
        }
        for (final child in processes) {
          child.stdin.writeln('GO');
          await child.stdin.close();
        }
        for (var i = 0; i < processes.length; i++) {
          expect(
            await lines[i].moveNext().timeout(const Duration(seconds: 30)),
            isTrue,
          );
          expect(lines[i].current, 'RESOLVED');
          await lines[i].cancel();
          expect(await processes[i].exitCode, 0, reason: await errors[i]);
        }
        expect(exchanges, 1);
        expect(store.read().refreshToken, 'rotated-test-refresh');
      } finally {
        for (final child in processes) {
          child.kill();
        }
        await subscription.cancel();
        await server.close(force: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('OS releases an abandoned lock after process death', () async {
    final child = await Process.start(
      Platform.resolvedExecutable,
      await childArguments(store.path),
    );
    final ready = await utf8.decoder
        .bind(child.stdout)
        .transform(const LineSplitter())
        .first;
    expect(ready, 'LOCKED');
    child.kill(
      Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
    );
    await child.exitCode;
    final value = await store
        .locked(() async => 42)
        .timeout(const Duration(seconds: 10));
    expect(value, 42);
  });
}
