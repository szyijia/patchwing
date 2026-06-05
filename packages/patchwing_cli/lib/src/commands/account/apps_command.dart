import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/code_push_client_wrapper.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';
import 'package:patchwing_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';

/// {@template apps_command}
/// `patchwing account apps`
/// List the apps the current user has access to.
/// {@endtemplate}
class AppsCommand extends PatchwingCommand {
  /// {@macro apps_command}
  AppsCommand();

  @override
  String get name => 'apps';

  @override
  String get description =>
      'List the apps you have access to.\n\n'
      'Example output (space-separated: app_id  display_name  '
      'latest_release_version  latest_patch_number):\n'
      '  01H...  Acme Mobile  1.2.3  4\n'
      '  01J...  Acme Internal  -  -\n\n'
      '"-" indicates no release or patch has been published yet.\n\n'
      '${PatchwingCommand.jsonHint('patchwing account apps --json')}';

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (error) {
      return error.exitCode.code;
    }

    final List<AppMetadata> apps;
    try {
      apps = await codePushClientWrapper.getApps();
    } on ProcessExit catch (e) {
      if (isJsonMode) {
        emitJsonError(
          code: JsonErrorCode.fetchFailed,
          message: 'Failed to fetch apps.',
        );
        return e.exitCode;
      }
      rethrow;
    }

    if (isJsonMode) {
      emitJsonSuccess({
        'apps': [
          for (final app in apps)
            {
              'app_id': app.appId,
              'display_name': app.displayName,
              'latest_release_version': app.latestReleaseVersion,
              'latest_patch_number': app.latestPatchNumber,
            },
        ],
      });
      return ExitCode.success.code;
    }

    if (apps.isEmpty) {
      logger.info('No apps found.');
      return ExitCode.success.code;
    }

    for (final app in apps) {
      logger.info(
        '${app.appId}  ${lightCyan.wrap(app.displayName)}  '
        '${app.latestReleaseVersion ?? '-'}  '
        '${app.latestPatchNumber ?? '-'}',
      );
    }

    return ExitCode.success.code;
  }
}
