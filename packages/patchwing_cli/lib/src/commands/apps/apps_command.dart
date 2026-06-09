import 'package:patchwing_cli/src/commands/apps/apps.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// Commands for managing Patchwing apps.
class AppsRootCommand extends PatchwingCommand {
  /// Creates an apps command.
  AppsRootCommand() {
    addSubcommand(AppsCreateCommand());
    addSubcommand(AppsListCommand());
  }

  @override
  String get name => 'apps';

  @override
  String get description => 'Manage Patchwing apps.';
}
