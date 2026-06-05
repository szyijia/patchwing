import 'package:patchwing_cli/src/commands/account/account.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template account_command}
/// Commands for inspecting the current Patchwing account.
/// {@endtemplate}
class AccountCommand extends PatchwingCommand {
  /// {@macro account_command}
  AccountCommand() {
    addSubcommand(AppsCommand());
    addSubcommand(OrgsCommand());
    addSubcommand(WhoamiCommand());
  }

  @override
  String get name => 'account';

  @override
  String get description => 'Manage your Patchwing account.';
}
