import 'package:shorebird_cli/src/commands/commands.dart';
import 'package:shorebird_cli/src/shorebird_command.dart';

/// {@template flutter_versions_command}
/// `pw flutter versions`
/// Manage your Shorebird Flutter versions.
/// {@endtemplate}
class FlutterVersionsCommand extends ShorebirdCommand {
  /// {@macro flutter_versions_command}
  FlutterVersionsCommand() {
    addSubcommand(FlutterVersionsListCommand());
  }

  @override
  String get description => 'Manage your Patchwing Flutter versions.';

  @override
  String get name => 'versions';
}
