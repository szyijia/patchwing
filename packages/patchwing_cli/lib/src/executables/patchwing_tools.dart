import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';

/// A reference to a [PatchwingTools] instance.
final patchwingToolsRef = create(PatchwingTools.new);

/// The [PatchwingTools] instance available in the current zone.
PatchwingTools get patchwingTools => read(patchwingToolsRef);

/// {@template package_failed_exception}
/// An exception thrown when packaging a patch fails.
/// {@endtemplate}
class PackageFailedException implements Exception {
  /// {@macro package_failed_exception}
  PackageFailedException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => message;
}

/// A wrapper around the `patchwing_tools` executable.
///
/// Used to access many commands related to Patchwing's flutter tooling.
class PatchwingTools {
  /// Returns whether the current flutter version supports this tool.
  ///
  /// This should be used to check if the tool is supported before running
  /// any commands.
  bool isSupported() {
    return patchwingToolsDirectory.existsSync();
  }

  /// The directory containing the `patchwing_tools` package.
  Directory get patchwingToolsDirectory {
    final dir = Directory(
      p.join(patchwingEnv.flutterDirectory.path, 'packages', 'patchwing_tools'),
    );
    return dir;
  }

  Future<PatchwingProcessResult> _run(List<String> args) {
    return process.run(
      patchwingEnv.dartBinaryFile.path,
      ['run', 'patchwing_tools', 'package', ...args],
      workingDirectory: patchwingToolsDirectory.path,
    );
  }

  /// Creates a package with the [patchPath] and writes it to [outputPath].
  ///
  /// Packages contains all the information needed by Patchwing for an update.
  Future<void> package({
    required String patchPath,
    required String outputPath,
  }) async {
    final packageArguments = ['-p', patchPath, '-o', outputPath];

    final result = await _run(packageArguments);

    if (result.exitCode != ExitCode.success.code) {
      throw PackageFailedException('''
Failed to create package (exit code ${result.exitCode}).
  stdout: ${result.stdout}
  stderr: ${result.stderr}''');
    }
  }
}
