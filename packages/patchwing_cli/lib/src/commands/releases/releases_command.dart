import 'package:patchwing_cli/src/commands/releases/releases.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template releases_command}
/// Commands for managing Patchwing releases.
/// {@endtemplate}
class ReleasesCommand extends PatchwingCommand {
  /// {@macro releases_command}
  ReleasesCommand() {
    addSubcommand(GetApksCommand());
    addSubcommand(ReleasesInfoCommand());
    addSubcommand(ReleasesListCommand());
  }

  @override
  String get name => 'releases';

  @override
  String get description => 'Manage Patchwing releases.';
}
