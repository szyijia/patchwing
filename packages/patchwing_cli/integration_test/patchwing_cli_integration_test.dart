import 'dart:convert';
import 'dart:io';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/auth/auth.dart';
import 'package:patchwing_cli/src/config/config.dart';
import 'package:patchwing_cli/src/http_client/http_client.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

R runWithOverrides<R>(R Function() body) {
  return runScoped(
    body,
    values: {authRef, httpClientRef, loggerRef, platformRef, patchwingEnvRef},
  );
}

void main() {
  final patchwingHostedURL = Platform.environment['PATCHWING_HOSTED_URL'];
  if (patchwingHostedURL == null || patchwingHostedURL.isEmpty) {
    throw Exception('PATCHWING_HOSTED_URL environment variable is not set.');
  }
  final logger = Logger();
  final client = runWithOverrides(
    () => CodePushClient(
      httpClient: Auth().client,
      hostedUri: Uri.parse(patchwingHostedURL),
    ),
  );

  /// Helper function to run a command in the shell, meant to be used in tests.
  ///
  /// It will take a command string, like `patchwing --version`, run it in the
  /// shell, and return the result.
  ProcessResult runCommand(
    String command, {
    required String workingDirectory,
    Logger? logger,
  }) {
    logger ??= Logger();
    final parts = command.split(' ');
    final executable = parts.first;
    final arguments = parts.skip(1).toList();
    logger.info('Running $command in $workingDirectory');
    final result = Process.runSync(
      executable,
      arguments,
      runInShell: true,
      workingDirectory: workingDirectory,
    );
    logger
      ..info('Exited with code: ${result.exitCode}')
      ..info(result.stdout.toString());
    if (result.exitCode != ExitCode.success.code) {
      logger.err(result.stderr.toString());
    }
    return result;
  }

  test('--version', () {
    final result = runCommand('patchwing --version', workingDirectory: '.');
    expect(result.exitCode, equals(0));
    expect(result.stdout, stringContainsInOrder(['Engine', 'revision']));
  });

  test(
    'create an app with a release and patch',
    () async {
      final authToken = Platform.environment[patchwingTokenEnvVar];
      if (authToken == null || authToken.isEmpty) {
        throw Exception(
          '$patchwingTokenEnvVar environment variable is not set.',
        );
      }
      const releaseVersion = '1.0.0+1';
      const platform = 'android';
      const arch = 'aarch64';
      const channel = 'stable';

      final uuid = const Uuid().v4().replaceAll('-', '_');
      final testAppName = 'test_app_$uuid';
      final tempDir = Directory.systemTemp.createTempSync();
      final subDirWithSpace = Directory(
        p.join(tempDir.path, 'flutter directory'),
      )..createSync();
      var cwd = subDirWithSpace.path;

      // Create the default flutter counter app
      logger.info('running `patchwing create $testAppName` in $cwd');
      final createAppResult = runCommand(
        'patchwing create $testAppName',
        workingDirectory: cwd,
      );
      expect(createAppResult.exitCode, equals(0));

      cwd = p.join(cwd, testAppName);

      final patchwingYamlPath = p.join(cwd, 'patchwing.yaml');
      final patchwingYamlText = File(patchwingYamlPath).readAsStringSync();
      final patchwingYaml = checkedYamlDecode(
        patchwingYamlText,
        (m) => PatchwingYaml.fromJson(m!),
      );

      // Verify that we have no releases for this app
      await expectLater(
        runWithOverrides(client.getApps),
        completion(
          contains(
            isA<AppMetadata>()
                .having((a) => a.appId, 'appId', patchwingYaml.appId)
                .having(
                  (a) => a.latestReleaseVersion,
                  'latestReleaseVersion',
                  null,
                )
                .having((a) => a.latestPatchNumber, 'latestPatchNumber', null),
          ),
        ),
      );

      // Create an Android release.
      final patchwingReleaseResult = runCommand(
        'patchwing release android --verbose',
        workingDirectory: cwd,
      );
      expect(patchwingReleaseResult.exitCode, equals(0));
      expect(
        patchwingReleaseResult.stdout,
        contains('Published Release $releaseVersion!'),
      );

      // Verify that no patch is available.
      await expectLater(
        isPatchAvailable(
          appId: patchwingYaml.appId,
          releaseVersion: releaseVersion,
          platform: platform,
          arch: arch,
          channel: channel,
        ),
        completion(isFalse),
      );

      // Verify that the release was created.
      await expectLater(
        runWithOverrides(client.getApps),
        completion(
          contains(
            isA<AppMetadata>()
                .having((a) => a.appId, 'appId', patchwingYaml.appId)
                .having(
                  (a) => a.latestReleaseVersion,
                  'latestReleaseVersion',
                  releaseVersion,
                )
                .having((a) => a.latestPatchNumber, 'latestPatchNumber', null),
          ),
        ),
      );

      // Create an Android patch.
      final patchwingPatchResult = runCommand(
        'patchwing patch android --verbose',
        workingDirectory: cwd,
      );
      expect(patchwingPatchResult.exitCode, equals(0));
      expect(patchwingPatchResult.stdout, contains('Published Patch 1!'));

      // Verify that the patch is available.
      await expectLater(
        isPatchAvailable(
          appId: patchwingYaml.appId,
          releaseVersion: releaseVersion,
          platform: platform,
          arch: arch,
          channel: channel,
        ),
        completion(isTrue),
      );

      // Verify that the patch was created.
      await expectLater(
        runWithOverrides(client.getApps),
        completion(
          contains(
            isA<AppMetadata>()
                .having((a) => a.appId, 'appId', patchwingYaml.appId)
                .having(
                  (a) => a.latestReleaseVersion,
                  'latestReleaseVersion',
                  '1.0.0+1',
                )
                .having((a) => a.latestPatchNumber, 'latestPatchNumber', 1),
          ),
        ),
      );

      // Delete the app to clean up after ourselves.
      await expectLater(
        runWithOverrides(() => client.deleteApp(appId: patchwingYaml.appId)),
        completes,
      );

      // Verify that the app was deleted.
      await expectLater(
        runWithOverrides(client.getApps),
        completion(
          isNot(
            contains(
              isA<AppMetadata>().having(
                (a) => a.appId,
                'appId',
                patchwingYaml.appId,
              ),
            ),
          ),
        ),
      );

      // Verify that no patch is available.
      await expectLater(
        isPatchAvailable(
          appId: patchwingYaml.appId,
          releaseVersion: releaseVersion,
          platform: platform,
          arch: arch,
          channel: channel,
        ),
        completion(isFalse),
      );
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

Future<bool> isPatchAvailable({
  required String appId,
  required String releaseVersion,
  required String platform,
  required String arch,
  required String channel,
}) async {
  final response = await http.post(
    Uri.parse(
      Platform.environment['PATCHWING_HOSTED_URL']!,
    ).replace(path: '/api/v1/patches/check'),
    body: jsonEncode({
      'release_version': releaseVersion,
      'platform': platform,
      'arch': arch,
      'app_id': appId,
      'channel': channel,
    }),
  );
  if (response.statusCode != HttpStatus.ok) {
    throw Exception('Patch Check Failure: ${response.statusCode}');
  }
  final json = jsonDecode(response.body) as Map<String, dynamic>;
  return json['patch_available'] as bool;
}
