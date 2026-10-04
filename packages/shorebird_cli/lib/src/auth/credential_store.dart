import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:googleapis_auth/googleapis_auth.dart';

/// Synchronizes interactive CLI credentials, including rotating refresh tokens.
/// The lock file is stable: never rename or delete it when replacing
/// credentials.
class CredentialStore {
  /// Uses the credential file at [path] and a separate, stable lock file.
  CredentialStore(this.path);

  /// The credential file shared by CLI processes.
  final String path;
  static final _queues = <String, Future<void>>{};

  /// Serializes credential operations within and between CLI processes.
  Future<T> locked<T>(Future<T> Function() action) async {
    final key = File(path).absolute.path;
    final previous = _queues[key] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[key] = done.future;
    await previous;
    RandomAccessFile? handle;
    var acquired = false;
    try {
      final file = File('$path.lock');
      file.parent.createSync(recursive: true);
      if (FileSystemEntity.isLinkSync(file.path)) {
        throw StateError('Credential lock must not be a symbolic link.');
      }
      handle = await file.open(mode: FileMode.append);
      await handle.lock(FileLock.blockingExclusive);
      acquired = true;
      return await action();
    } finally {
      try {
        if (acquired) await handle!.unlock();
      } finally {
        try {
          await handle?.close();
        } finally {
          done.complete();
          if (identical(_queues[key], done.future)) {
            unawaited(_queues.remove(key));
          }
        }
      }
    }
  }

  /// Reads the current file, failing explicitly when removed or corrupted.
  AccessCredentials read() {
    final file = File(path);
    if (!file.existsSync()) {
      throw StateError('CLI credentials were removed. Run pw login again.');
    }
    return AccessCredentials.fromJson(
      jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    );
  }

  /// Call only while holding [locked]. Same-directory rename is atomic.
  void write(AccessCredentials credentials) {
    final destination = File(path);
    destination.parent.createSync(recursive: true);
    final temporaryDirectory = destination.parent.createTempSync(
      '.credentials-',
    );
    try {
      if (!Platform.isWindows) {
        final result = Process.runSync('chmod', [
          '700',
          temporaryDirectory.path,
        ]);
        if (result.exitCode != 0) {
          throw StateError('Cannot protect credentials.');
        }
      }
      final temporary = File('${temporaryDirectory.path}/credentials.json')
        ..writeAsStringSync(
          jsonEncode(credentials.toJson()),
          flush: true,
        );
      if (!Platform.isWindows) {
        final result = Process.runSync('chmod', ['600', temporary.path]);
        if (result.exitCode != 0) {
          throw StateError('Cannot protect credentials.');
        }
      }
      temporary.renameSync(path);
    } finally {
      temporaryDirectory.deleteSync(recursive: true);
    }
  }

  /// Reloads under the lock and refreshes only if still expired.
  Future<AccessCredentials> resolve(
    AccessCredentials current,
    Future<AccessCredentials> Function(AccessCredentials) refresh,
  ) => locked(() async {
    final latest = read();
    // Never silently send an existing command as a different logged-in user.
    if (_identity(latest) != _identity(current)) {
      throw StateError('CLI login changed while this command was running.');
    }
    if (!latest.accessToken.hasExpired) return latest;
    final updated = await refresh(latest);
    write(updated);
    return updated;
  });

  String _identity(AccessCredentials credentials) {
    final token = credentials.idToken;
    if (token == null) throw StateError('Interactive credentials need a JWT.');
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const FormatException('Invalid credential JWT');
    }
    final claims =
        jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
            )
            as Map<String, dynamic>;
    return jsonEncode([claims['iss'], claims['sub'], claims['sid']]);
  }
}
