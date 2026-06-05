import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_flutter.dart';

/// {@template flutter_versions_list_command}
/// `patchwing flutter versions list`
/// List available Flutter versions.
/// {@endtemplate}
class FlutterVersionsListCommand extends PatchwingCommand {
  /// {@macro flutter_versions_list_command}
  FlutterVersionsListCommand();

  @override
  String get description => 'List available Flutter versions.';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    final progress = isJsonMode
        ? null
        : logger.progress('Fetching Flutter versions');

    String? currentVersion;
    try {
      currentVersion = await patchwingFlutter.getVersionString();
    } on ProcessException catch (error) {
      logger.detail('Unable to determine Flutter version.\n${error.message}');
    }

    final List<String> versions;
    try {
      versions = await patchwingFlutter.getVersions();
      progress?.cancel();
    } on Exception catch (error) {
      if (isJsonMode) {
        emitJsonError(
          code: JsonErrorCode.fetchFailed,
          message: 'Failed to fetch Flutter versions: $error',
        );
        return ExitCode.software.code;
      }
      progress?.fail('Failed to fetch Flutter versions.');
      logger.err('$error');
      return ExitCode.software.code;
    }

    if (isJsonMode) {
      emitJsonSuccess({
        'current_version': currentVersion,
        'versions': versions.reversed.toList(),
      });
      return ExitCode.success.code;
    }

    logger.info('📦 Flutter Versions');
    for (final version in versions.reversed) {
      logger.info(
        version == currentVersion ? lightCyan.wrap('✓ $version') : '  $version',
      );
    }
    return ExitCode.success.code;
  }
}
