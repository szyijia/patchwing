import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/code_push_client_wrapper.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';
import 'package:patchwing_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';

/// {@template whoami_command}
/// `patchwing account whoami`
/// Show the currently authenticated Patchwing user.
/// {@endtemplate}
class WhoamiCommand extends PatchwingCommand {
  /// {@macro whoami_command}
  WhoamiCommand();

  @override
  String get name => 'whoami';

  @override
  String get description =>
      'Show the currently authenticated Patchwing user.\n\n'
      'Example output:\n'
      '  ID:             42\n'
      '  Email:          user@example.com\n'
      '  Display name:   Example User\n'
      '  Plan:           paid\n'
      '  Overage limit:  10000\n\n'
      'Plan is "paid" (active Patchwing subscription) or "free".\n'
      'Overage limit is the max pay-as-you-go patch installs allowed '
      'beyond your plan ("none" if unset).\n\n'
      '${PatchwingCommand.jsonHint('patchwing account whoami --json')}';

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (error) {
      return error.exitCode.code;
    }

    final PrivateUser user;
    try {
      user = await codePushClientWrapper.getCurrentUser();
    } on ProcessExit catch (e) {
      if (isJsonMode) {
        emitJsonError(
          code: JsonErrorCode.fetchFailed,
          message: 'Failed to fetch account.',
        );
        return e.exitCode;
      }
      rethrow;
    }

    final plan = (user.hasActiveSubscription ?? false) ? 'paid' : 'free';

    if (isJsonMode) {
      emitJsonSuccess({
        'user': {
          'id': user.id,
          'email': user.email,
          'display_name': user.displayName,
          'plan': plan,
          'overage_limit': user.patchOverageLimit,
        },
      });
      return ExitCode.success.code;
    }

    logger
      ..info('ID:             ${user.id}')
      ..info('Email:          ${user.email}');
    if (user.displayName != null) {
      logger.info('Display name:   ${user.displayName}');
    }
    logger
      ..info('Plan:           $plan')
      ..info('Overage limit:  ${user.patchOverageLimit ?? 'none'}');

    return ExitCode.success.code;
  }
}
