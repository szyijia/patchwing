import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';

/// {@template patchwing_create_command}
/// `patchwing create`
/// Create a new Flutter app with Patchwing.
/// {@endtemplate}
class CreateCommand extends PatchwingProxyCommand {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a new Flutter project with Patchwing.';

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final createExitCode = await process.stream('flutter', [
      'create',
      ...results.rest,
    ]);

    if (createExitCode != ExitCode.success.code) {
      return createExitCode;
    }

    if (results.rest.contains('-h') || results.rest.contains('--help')) {
      return createExitCode;
    }

    return runScoped(
      () => runner!.run(['init']),
      values: {
        patchwingEnvRef.overrideWith(
          () => PatchwingEnv(
            flutterProjectRootOverride: p.absolute(
              p.normalize(results.rest.first),
            ),
          ),
        ),
      },
    );
  }
}
