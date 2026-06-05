import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/engine_config.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';

/// A reference to a [PatchwingProcess] instance.
final processRef = create(PatchwingProcess.new);

/// The [PatchwingProcess] instance available in the current zone.
PatchwingProcess get process => read(processRef);

/// A wrapper around [Process] that replaces executables to Patchwing-vended
/// versions.
// This may need a better name, since it returns "Process" it's more a
// "ProcessFactory" than a "Process".
class PatchwingProcess {
  /// Creates a PatchwingProcess.
  PatchwingProcess({
    ProcessWrapper? processWrapper, // For mocking PatchwingProcess.
  }) : processWrapper = processWrapper ?? ProcessWrapper();

  /// The underlying process wrapper.
  final ProcessWrapper processWrapper;

  /// Starts a process, streams the output in real-time, and returns the exit
  /// code.
  ///
  /// Uses `ProcessStartMode.inheritStdio` so the child (flutter, gradlew,
  /// gen_snapshot) shares our terminal fds and can render its spinner + ANSI
  /// output the way users expect. The cost: the child's bytes never pass
  /// through the `LoggingStdout` `IOOverrides` installed in
  /// `bin/patchwing.dart`, so `flutter build` stderr is absent from the
  /// patchwing log file — on a build failure users see the real error on
  /// screen but the log only has `Failed to build AAB. Exited with code 1`
  /// (https://github.com/patchwingtech/patchwing/issues/3703). Piping
  /// through Dart would capture stderr but turns `stdout.hasTerminal` false
  /// on the child side, regressing the interactive UX; a pty or per-fd
  /// shell tee would fix both but costs a dependency / POSIX-only path.
  /// Accepting the logging gap for now.
  Future<int> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    void Function(Process process)? onStart,
  }) async {
    final process = await start(
      executable,
      arguments,
      environment: environment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    onStart?.call(process);
    return process.exitCode;
  }

  /// Runs the process and returns the result.
  Future<PatchwingProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) async {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.run] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = await processWrapper.run(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
      runInShell: runInShell,
    );

    _logResult(result);

    return result;
  }

  /// Runs the process synchronously and returns the result.
  PatchwingProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.runSync] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = processWrapper.runSync(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
    );

    _logResult(result);

    return result;
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool useVendedFlutter = true,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    final resolvedEnvironment = environment ?? {};
    if (useVendedFlutter) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.start] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    return processWrapper.start(
      resolvedExecutable,
      resolvedArguments,
      environment: resolvedEnvironment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }

  Map<String, String> _resolveEnvironment(
    Map<String, String>? baseEnvironment, {
    required String executable,
    required bool useVendedFlutter,
  }) {
    final resolvedEnvironment = baseEnvironment ?? {};
    if (useVendedFlutter) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }

    return resolvedEnvironment;
  }

  String _resolveExecutable(
    String executable, {
    required bool useVendedFlutter,
  }) {
    if (useVendedFlutter && executable == 'flutter') {
      return _sanitizeExecutablePath(patchwingEnv.flutterBinaryFile.path);
    }
    return _sanitizeExecutablePath(executable);
  }

  /// Sanitizes the executable path on Windows.
  /// https://github.com/dart-lang/sdk/issues/37751
  String _sanitizeExecutablePath(String executable) {
    if (executable.isEmpty) return executable;
    if (!platform.isWindows) return executable;
    if (executable.contains(' ') && !executable.contains('"')) {
      // Use quoted strings to indicate where the file name ends and the
      // arguments begin; otherwise, the file name is ambiguous.
      return '"$executable"';
    }
    return executable;
  }

  List<String> _resolveArguments(
    String executable,
    List<String> arguments, {
    required bool useVendedFlutter,
  }) {
    var resolvedArguments = arguments;
    if (executable == 'flutter') {
      if (logger.level == Level.verbose) {
        /// We explicitly add the `--verbose` flag to flutter commands when the
        /// patchwing command was run with `--verbose`
        /// (e.g. `patchwing release ios --verbose`).
        resolvedArguments = [...resolvedArguments, '--verbose'];
      }
      if (useVendedFlutter && engineConfig.localEngine != null) {
        resolvedArguments = [
          '--local-engine-src-path=${engineConfig.localEngineSrcPath}',
          '--local-engine=${engineConfig.localEngine}',
          '--local-engine-host=${engineConfig.localEngineHost}',
          ...resolvedArguments,
        ];
      }
    }

    return resolvedArguments;
  }

  void _logResult(PatchwingProcessResult result) {
    logger.detail('Exited with code ${result.exitCode}');

    final stdout = result.stdout as String?;
    if (stdout != null && stdout.isNotEmpty) {
      logger.detail('''

stdout:
$stdout''');
    }

    final stderr = result.stderr as String?;
    if (stderr != null && stderr.isNotEmpty) {
      logger.detail('''

stderr:
$stderr''');
    }
  }

  Map<String, String> _environmentOverrides({required String executable}) {
    // Patchwing 使用本机 vendor/flutter，并通过 --local-engine 指向本地预编译
    // 引擎产物，不需要从远程 CDN 下载 flutter_infra_release 引擎二进制。
    // 因此这里不再覆写 FLUTTER_STORAGE_BASE_URL，避免误导 flutter 工具去
    // patchwing CDN 拉取不存在的产物（404）。
    // 如果用户本地设置了 FLUTTER_STORAGE_BASE_URL（例如国内镜像
    // https://storage.flutter-io.cn），将自动沿用其设置。
    return {};
  }
}

/// Result from running a process.
class PatchwingProcessResult {
  /// Creates a new [PatchwingProcessResult].
  const PatchwingProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The exit code of the process.
  final int exitCode;

  /// The standard output of the process.
  final dynamic stdout;

  /// The standard error of the process.
  final dynamic stderr;
}

/// A wrapper around [Process] that can be mocked for testing.
// coverage:ignore-start
@visibleForTesting
class ProcessWrapper {
  /// Runs the process and returns the result.
  Future<PatchwingProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool? runInShell,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return PatchwingProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Runs the process synchronously and returns the result.
  PatchwingProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) {
    final result = Process.runSync(
      executable,
      arguments,
      environment: environment,
      runInShell: Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return PatchwingProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      environment: environment,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }
}

// coverage:ignore-end
