import 'package:patchwing_cli/src/commands/patches/patches.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template patches_command}
/// Commands for managing Patchwing patches.
/// {@endtemplate}
class PatchesCommand extends PatchwingCommand {
  /// {@macro patches_command}
  PatchesCommand() {
    addSubcommand(PatchesInfoCommand());
    addSubcommand(PatchesListCommand());
    addSubcommand(PromoteCommand());
    addSubcommand(SetTrackCommand());
  }

  @override
  String get name => 'patches';

  @override
  String get description => 'Manage Patchwing patches.';
}
