import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/auth/auth.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template login_command}
/// `patchwing login`
/// Login as a new Patchwing user.
/// {@endtemplate}
class LoginCommand extends PatchwingCommand {
  LoginCommand() {
    argParser
      ..addOption(
        'email',
        abbr: 'e',
        help: 'Login with email and password (skips browser OAuth).',
      )
      ..addOption(
        'password',
        abbr: 'p',
        help: 'Password for email login.',
      );
  }

  @override
  String get description => 'Login as a new Patchwing user.';

  @override
  String get name => 'login';

  @override
  Future<int> run() async {
    if (auth.isAuthenticated) {
      final emailDisplay = auth.email;
      logger
        ..info(
          emailDisplay != null
              ? 'You are already logged in as <$emailDisplay>.'
              : 'You are already authenticated via API key.',
        )
        ..info(
          'Run ${lightCyan.wrap('patchwing logout')} to log out and try again.',
        );
      return ExitCode.success.code;
    }

    final email = results['email'] as String?;
    final password = results['password'] as String?;

    // 如果提供了 email，则使用密码登录
    if (email != null || password != null) {
      if (email == null || password == null) {
        logger.err(
          'Both --email and --password are required for direct login.',
        );
        return ExitCode.usage.code;
      }

      try {
        await auth.loginWithPassword(email: email, password: password);
      } on Exception catch (error) {
        logger.err(error.toString());
        return ExitCode.software.code;
      }

      logger.info('''

🎉 ${lightGreen.wrap('Welcome to Patchwing! You are now logged in as <${auth.email}>.')}

🔑 Credentials are stored in ${lightCyan.wrap(auth.credentialsFilePath)}.
🚪 To logout use: "${lightCyan.wrap('patchwing logout')}".''');
      return ExitCode.success.code;
    }

    // 否则使用浏览器 OAuth 登录
    try {
      await auth.login(prompt: prompt);
    } on UserNotFoundException catch (error) {
      final consoleUri = Uri.https('console.patchwing.net');
      logger
        ..err('''
We could not find a Patchwing account for ${error.email}.''')
        ..info(
          """If you have not yet created an account, you can do so at "${link(uri: consoleUri)}". If you believe this is an error, please reach out to us via Discord, we're happy to help!""",
        );
      return ExitCode.software.code;
    } on Exception catch (error) {
      logger.err(error.toString());
      return ExitCode.software.code;
    }

    logger.info('''

🎉 ${lightGreen.wrap('Welcome to Patchwing! You are now logged in as <${auth.email}>.')}

🔑 Credentials are stored in ${lightCyan.wrap(auth.credentialsFilePath)}.
🚪 To logout use: "${lightCyan.wrap('patchwing logout')}".''');
    return ExitCode.success.code;
  }

  /// Prompt the user to log in.
  void prompt(String url) {
    logger.info('''
The Patchwing CLI needs your authorization to manage apps, releases, and patches on your behalf.

In a browser, visit this URL to log in:

${styleBold.wrap(styleUnderlined.wrap(lightCyan.wrap(url)))}

Waiting for your authorization...''');
  }
}
