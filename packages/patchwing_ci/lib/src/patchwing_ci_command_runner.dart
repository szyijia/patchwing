import 'package:args/command_runner.dart';
import 'package:patchwing_ci/src/commands/commands.dart';

/// The patchwing_ci command runner.
class PatchwingCiCommandRunner extends CommandRunner<int> {
  /// Creates a [PatchwingCiCommandRunner].
  PatchwingCiCommandRunner()
    : super('patchwing_ci', 'CI tooling for Dart/Flutter monorepos') {
    addCommand(AffectedPackagesCommand());
    addCommand(FlutterVersionCommand());
    addCommand(GenerateCommand());
    addCommand(UpdateActionsCommand());
    addCommand(VerifyCommand());
  }
}
