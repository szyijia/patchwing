import 'package:patchwing_cli/src/commands/commands.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template flutter_command}
/// `patchwing flutter`
/// Manage your Patchwing Flutter installation.
/// {@endtemplate}
class FlutterCommand extends PatchwingCommand {
  /// {@macro flutter_command}
  FlutterCommand() {
    addSubcommand(FlutterVersionsCommand());
    addSubcommand(FlutterConfigCommand());
  }

  @override
  String get description => 'Manage your Patchwing Flutter installation.';

  @override
  String get name => 'flutter';
}
