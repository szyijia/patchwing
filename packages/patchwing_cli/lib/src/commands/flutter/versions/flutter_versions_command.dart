import 'package:patchwing_cli/src/commands/commands.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template flutter_versions_command}
/// `patchwing flutter versions`
/// Manage your Patchwing Flutter versions.
/// {@endtemplate}
class FlutterVersionsCommand extends PatchwingCommand {
  /// {@macro flutter_versions_command}
  FlutterVersionsCommand() {
    addSubcommand(FlutterVersionsListCommand());
  }

  @override
  String get description => 'Manage your Patchwing Flutter versions.';

  @override
  String get name => 'versions';
}
