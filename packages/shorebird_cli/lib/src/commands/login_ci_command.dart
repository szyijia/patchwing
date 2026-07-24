import 'package:mason_logger/mason_logger.dart';
import 'package:shorebird_cli/src/logging/logging.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template login_ci_command}
/// `pw login:ci`
/// Removed — directs users to API keys instead.
/// {@endtemplate}
class LoginCiCommand extends ShorebirdCommand {
  @override
  String get description => 'Removed — use API keys instead.';

  @override
  String get name => 'login:ci';

  @override
  Future<int> run() async {
    logger.err(
      '''
pw login:ci has been replaced by API keys.

Create an API key at ${link(uri: Uri.parse('https://console.patchwing.net'))} and set it as your ${lightCyan.wrap('PATCHWING_TOKEN')} environment variable.

Learn more: ${link(uri: Uri.parse('https://docs.patchwing.net/account/api-keys/'))}''',
    );
    return ExitCode.usage.code;
  }
}
