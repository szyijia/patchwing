import 'package:patchwing_cli/src/commands/commands.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';

/// {@template cache_command}
/// `patchwing cache`
/// Manage the Patchwing cache.
/// {@endtemplate}
class CacheCommand extends PatchwingCommand {
  /// {@macro cache_command}
  CacheCommand() {
    addSubcommand(CleanCacheCommand());
  }

  @override
  String get description => 'Manage the Patchwing cache.';

  @override
  String get name => 'cache';
}
