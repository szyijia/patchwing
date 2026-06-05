import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/auth/auth.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template logout_command}
///
/// `patchwing logout`
/// Logout of the current Patchwing user.
/// {@endtemplate}
class LogoutCommand extends PatchwingCommand {
  @override
  String get description => 'Logout of the current Patchwing user.';

  @override
  String get name => 'logout';

  @override
  Future<int> run() async {
    if (!auth.isAuthenticated) {
      logger.info('You are already logged out.');
      return ExitCode.success.code;
    }

    final logoutProgress = logger.progress('Logging out of www.patchwing.net');
    await auth.logout();
    logoutProgress.complete();

    logger.info('${lightGreen.wrap('You are now logged out.')}');

    return ExitCode.success.code;
  }
}
