import 'dart:async';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:cli_completion/cli_completion.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/commands/commands.dart';
import 'package:patchwing_cli/src/engine_config.dart';
import 'package:patchwing_cli/src/engine_manager.dart';
import 'package:patchwing_cli/src/interactive_mode.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_artifacts.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_flutter.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';
import 'package:patchwing_cli/src/patchwing_version.dart';
import 'package:patchwing_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:patchwing_cli/src/version.dart';

/// The name of the executable.
const executableName = 'patchwing';

/// The name of the package (e.g. name in the pubspec.yaml).
const packageName = 'patchwing_cli';

/// The package description.
const description = 'The patchwing command-line tool';

/// {@template patchwing_cli_command_runner}
/// A [CommandRunner] for the CLI.
///
/// ```sh
/// $ patchwing --version
/// ```
/// {@endtemplate}
class PatchwingCliCommandRunner extends CompletionCommandRunner<int> {
  /// {@macro patchwing_cli_command_runner}
  PatchwingCliCommandRunner() : super(executableName, description) {
    argParser
      ..addFlag('version', negatable: false, help: 'Print the current version.')
      ..addFlag(
        'json',
        negatable: false,
        help: 'Output results in JSON format (implies non-interactive mode).',
      )
      ..addFlag(
        'verbose',
        abbr: 'v',
        help: 'Noisy logging, including all shell commands executed.',
      )
      ..addOption(
        'local-engine-src-path',
        hide: true,
        help:
            'Path to your engine src directory, if you are building Flutter '
            'locally.',
      )
      ..addOption(
        'local-engine',
        hide: true,
        help:
            'Name of a build output within the engine out directory, if you '
            'are building Flutter locally.',
      )
      ..addOption(
        'local-engine-host',
        hide: true,
        help: 'The build of the local engine to use as the host platform.',
      )
      ..addOption(
        'storage-url',
        help:
            'Override the base URL used to download Patchwing artifacts '
            '(engine, aot-tools, patch tool, flutter SDK cache). '
            'Defaults to https://cdn.patchwing.net. '
            'Can also be set via PATCHWING_STORAGE_URL env var or the '
            '`storage_base_url` field in patchwing.yaml.',
      );

    addCommand(AccountCommand());
    addCommand(AppsRootCommand());
    addCommand(CacheCommand());
    addCommand(CreateCommand());
    addCommand(DoctorCommand());
    addCommand(FlutterCommand());
    addCommand(InitCommand());
    addCommand(LoginCommand());
    addCommand(LoginCiCommand());
    addCommand(LogoutCommand());
    addCommand(PatchCommand());
    addCommand(PatchesCommand());
    addCommand(PreviewCommand());
    addCommand(ReleaseCommand());
    addCommand(ReleasesCommand());
    addCommand(UpgradeCommand());
  }

  @override
  void printUsage() => logger.info(usage);

  @override
  Future<int> run(Iterable<String> args) async {
    final argsList = args.toList();
    // Detect `--json` from the raw argv so that parse-time failures
    // (unknown flags, malformed input) can still emit a JSON envelope.
    // `parse(args)` throws before we'd otherwise read this flag.
    final jsonModeFromArgs = argsList.contains('--json');

    try {
      final topLevelResults = parse(argsList);

      final localEngineSrcPath =
          topLevelResults['local-engine-src-path'] as String?;
      final localEngine = topLevelResults['local-engine'] as String?;
      final localEngineHost = topLevelResults['local-engine-host'] as String?;
      final storageUrlOverride = topLevelResults['storage-url'] as String?;

      final localEngineArgs = [
        localEngineSrcPath,
        localEngine,
        localEngineHost,
      ];
      final localEngineArgsAreNull = localEngineArgs.every(
        (arg) => arg == null,
      );
      final localEngineArgsAreNotNull = localEngineArgs.every(
        (arg) => arg != null,
      );
      // 是否用户显式指定了 --local-engine 三件套（决定后续是走
      // PatchwingLocalEngineArtifacts 还是 PatchwingCachedArtifacts）。
      final EngineConfig? explicitEngineConfig;
      if (localEngineArgsAreNotNull) {
        explicitEngineConfig = EngineConfig(
          localEngineSrcPath: localEngineSrcPath,
          localEngine: localEngine,
          localEngineHost: localEngineHost,
        );
      } else if (localEngineArgsAreNull) {
        explicitEngineConfig = null; // 走 EngineManager 自动解析
      } else {
        // Only some local engine args were provided, this is invalid.
        throw ArgumentError(
          '''local-engine, local-engine-src, and local-engine-host must all be provided''',
        );
      }

      final jsonMode = topLevelResults['json'] == true;
      final process = PatchwingProcess();

      // 注意：EngineManager.resolveEngineConfig() 内部会调用
      // logger.progress(...)（走 ScopedRef），因此必须在 runScoped 内部调用。
      // 这里我们分两步：
      //   (1) 外层 runScoped 提供 logger / process / engineManager 等基础 ref；
      //   (2) 在外层内部异步解析 engineConfig，再用一个内层 runScoped 注入
      //       engineConfigRef + patchwingArtifactsRef，最后运行 runCommand。
      Future<int?> resolveAndRun() async {
        // In JSON mode, suppress verbose logging — it writes to stdout and
        // would corrupt the JSON output. Verbose output still goes to the
        // log file via PatchwingLogger.detail.
        if (!jsonMode && topLevelResults['verbose'] == true) {
          logger.level = Level.verbose;
        }

        final EngineConfig engineConfig;
        if (explicitEngineConfig != null) {
          engineConfig = explicitEngineConfig;
        } else if (_commandRequiresEngineConfig(topLevelResults)) {
          // 只有会调用 vended Flutter / local-engine 的命令才解析或下载 engine。
          // 纯 API 命令（login/apps/releases list 等）不能因为 engine/CDN 问题失败。
          final targetAbi = _readFirstTargetPlatform(topLevelResults);
          final resolved = await const EngineManager().resolveEngineConfig(
            null,
            targetAbi,
          );
          engineConfig = resolved ?? const EngineConfig.empty();
        } else {
          engineConfig = const EngineConfig.empty();
        }

        final patchwingArtifacts = engineConfig.localEngineSrcPath != null
            ? const PatchwingLocalEngineArtifacts()
            : const PatchwingCachedArtifacts();

        return runScoped<Future<int?>>(
          () => runCommand(topLevelResults),
          values: {
            engineConfigRef.overrideWith(() => engineConfig),
            patchwingArtifactsRef.overrideWith(() => patchwingArtifacts),
          },
        );
      }

      Future<int?> runWithBaseRefs() => runScoped<Future<int?>>(
        resolveAndRun,
        values: {
          engineManagerRef.overrideWith(EngineManager.new),
          isJsonModeRef.overrideWith(() => jsonMode),
          processRef.overrideWith(() => process),
          cliStorageUrlOverrideRef.overrideWith(() => storageUrlOverride),
        },
      );

      // Suppress ANSI escape codes when the user has opted into a
      // non-interactive output mode. When stdout/stderr aren't TTYs the io
      // package already disables ANSI automatically.
      final exitCode = jsonMode
          ? await overrideAnsiOutput<Future<int?>>(false, runWithBaseRefs)
          : await runWithBaseRefs();
      return exitCode ?? ExitCode.success.code;
    } on FormatException catch (e, stackTrace) {
      // On format errors, show the commands error message, root usage and
      // exit with an error code
      // FormatException from `parse(args)` is rare in practice; the JSON
      // branch is hard to trigger from real argv.
      // coverage:ignore-start
      if (jsonModeFromArgs) {
        JsonResult.error(
          code: JsonErrorCode.usageError,
          message: e.message,
          hint: 'Run: patchwing --help',
          command: executableName,
        ).write();
      } else {
        // coverage:ignore-end
        logger
          ..err(e.message)
          ..detail('$stackTrace')
          ..info('')
          ..info(usage);
      }
      return ExitCode.usage.code;
    } on UsageException catch (e) {
      // On usage errors, show the commands usage message and
      // exit with an error code
      if (jsonModeFromArgs) {
        JsonResult.error(
          code: JsonErrorCode.usageError,
          message: e.message,
          hint: 'Run: patchwing --help',
          command: executableName,
        ).write();
        return ExitCode.usage.code;
      }

      logger.err(e.message);
      if (e.message.contains('Could not find an option named')) {
        final String errorMessage;
        if (platform.isWindows) {
          errorMessage = '''
To proxy an option to the flutter command, use the '--' --<option> syntax.

Example:

${lightCyan.wrap("patchwing release android '--' --no-pub lib/main.dart")}''';
        } else {
          errorMessage = '''
To proxy an option to the flutter command, use the -- --<option> syntax.

Example:

${lightCyan.wrap('patchwing release android -- --no-pub lib/main.dart')}''';
        }

        logger.err(errorMessage);
      }

      logger
        ..info('')
        ..info(e.usage);
      return ExitCode.usage.code;
    }
  }

  bool _commandRequiresEngineConfig(ArgResults topLevelResults) {
    if (topLevelResults['version'] == true) return false;

    final commandResults = topLevelResults.command;
    if (commandResults?.rest.any((arg) => arg == '--help' || arg == '-h') ??
        false) {
      return false;
    }

    final command = commandResults?.name;
    return switch (command) {
      'create' => false,
      'doctor' || 'init' || 'patch' || 'preview' || 'release' => true,
      'flutter' => commandResults?.command?.name == 'config',
      _ => false,
    };
  }

  /// 读取子命令 `--target-platform` 的第一个值（如 android-arm），
  /// 供 EngineManager 选择 per-ABI 的 local-engine 目录。
  /// 未定义/未传该参数时返回 null（默认 arm64，历史行为）。
  String? _readFirstTargetPlatform(ArgResults topLevelResults) {
    final commandResults = topLevelResults.command;
    if (commandResults == null) return null;
    // 该子命令未定义 target-platform 参数时直接返回（ArgResults[] 对
    // 未定义参数名会抛 ArgumentError，用 options 判断避免 catch Error）
    if (!commandResults.options.contains('target-platform')) return null;
    // 未显式传参时返回 null（默认 arm64，历史行为）。必须判断 wasParsed：
    // 该参数是 multiOption 且 defaultsTo 全部 ABI，未传参时 argResults
    // 会返回默认值列表，直接读取会把默认构建误折叠到列表第一个 ABI。
    if (!commandResults.wasParsed('target-platform')) return null;
    final value = commandResults['target-platform'];
    String? first;
    if (value is String && value.isNotEmpty) {
      first = value;
    } else if (value is List && value.isNotEmpty) {
      first = value.first?.toString();
    }
    if (first == null || first.isEmpty) return null;
    // 支持逗号分隔（flutter 原生格式），local-engine 模式一次只构建一个 ABI
    final platforms =
        first.split(',').where((e) => e.trim().isNotEmpty).toList();
    if (platforms.length > 1 || (value is List && value.length > 1)) {
      logger.warn(
        'local-engine 模式一次只能构建一个 ABI，本次使用 ${platforms.first}；\n'
        '其余 ABI 请分别运行 --target-platform 单独构建',
      );
    }
    return platforms.first.trim();
  }

  @override
  Future<int?> runCommand(ArgResults topLevelResults) async {
    // Fast track completion command
    if (topLevelResults.command?.name == 'completion') {
      await super.runCommand(topLevelResults);
      return ExitCode.success.code;
    }

    final commandName =
        commandNameFromResults(topLevelResults) ?? executableName;

    // Run the command or show version
    int? exitCode;
    if (topLevelResults['version'] == true) {
      final flutterVersion = await _tryGetFlutterVersion();
      if (isJsonMode) {
        JsonResult.success(
          data: {
            'patchwing_version': packageVersion,
            'flutter_version': flutterVersion,
            'flutter_revision': patchwingEnv.flutterRevision,
            'engine_revision': patchwingEnv.patchwingEngineRevision,
          },
          command: 'version',
        ).write();
      } else {
        final patchwingFlutterPrefix = StringBuffer('Flutter');
        if (flutterVersion != null) {
          patchwingFlutterPrefix.write(' $flutterVersion');
        }
        // 显示编译期注入的构建版本（如 1.0.0+3f98759），便于核对
        // install.sh 安装的二进制与 CDN version.txt 是否一致；
        // publish_cli.sh 的版本校验也依赖这里输出的 +sha 段。
        final buildSuffix =
            patchwingBuildVersion == 'dev' ? '' : ' ($patchwingBuildVersion)';
        logger.info('''
Patchwing $packageVersion$buildSuffix • git@github.com:patchwingtech/patchwing.git
$patchwingFlutterPrefix • revision ${patchwingEnv.flutterRevision}
Engine • revision ${patchwingEnv.patchwingEngineRevision}''');
      }
      exitCode = ExitCode.success.code;
    } else {
      try {
        exitCode = await super.runCommand(topLevelResults);
      } on ProcessExit catch (error) {
        exitCode = error.exitCode;
        if (isJsonMode && error.exitCode != ExitCode.success.code) {
          JsonResult.error(
            code: JsonErrorCode.processExit,
            message: 'Process exited with code ${error.exitCode}.',
            command: commandName,
          ).write();
        }
      } on UsageException catch (e) {
        if (isJsonMode) {
          final subcommand = commandNameFromResults(topLevelResults);
          final hint = subcommand == null
              ? 'Run: patchwing --help'
              : 'Run: patchwing $subcommand --help'; // coverage:ignore-line
          JsonResult.error(
            code: JsonErrorCode.usageError,
            message: e.message,
            hint: hint,
            command: commandName,
          ).write();
        } else {
          logger
            ..err(e.message)
            ..info(e.usage);
        }
        // When on an usage exception we don't need to show the "if you aren't
        // sure" message, so we do an early return here.
        return ExitCode.usage.code;
      } on InteractivePromptRequiredException catch (e) {
        if (isJsonMode) {
          JsonResult.error(
            code: JsonErrorCode.interactivePromptRequired,
            message: e.promptText,
            hint: e.hint,
            command: commandName,
          ).write();
        } else {
          logger
            ..err(
              'Input was required for the following prompt but the CLI is '
              'running in a non-interactive context:',
            )
            ..err('  ${e.promptText}')
            ..info('')
            ..info('Hint: ${e.hint}');
        }
        return ExitCode.usage.code;

        // We explicitly want to catch all exceptions here to log them and show
        // the user a friendly message.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        if (isJsonMode) {
          JsonResult.error(
            code: JsonErrorCode.softwareError,
            message: '$error',
            command: commandName,
          ).write();
        }
        logger
          ..err('$error')
          ..detail('$stackTrace');
        exitCode = ExitCode.software.code;
      }
    }

    // `runCommand` returns null in when the --help flag is passed.
    if (!isJsonMode &&
        exitCode != null &&
        exitCode != ExitCode.success.code &&
        logger.level != Level.verbose) {
      final fileAnIssue = link(
        uri: Uri.parse(
          'https://github.com/patchwingtech/patchwing/issues/new/choose',
        ),
        message: 'file an issue',
      );
      logger.info('''

If you aren't sure why this command failed, re-run with the ${lightCyan.wrap('--verbose')} flag to see more information.

You can also $fileAnIssue if you think this is a bug. Please include the following log file in your report:
${currentRunLogFile.absolute.path}
''');
    }

    if (!isJsonMode &&
        topLevelResults.command?.name != UpgradeCommand.commandName) {
      await _checkForUpdates();
    }

    return exitCode;
  }

  Future<String?> _tryGetFlutterVersion() async {
    try {
      return await patchwingFlutter.getVersionString();
    } on Exception catch (error) {
      logger.detail('Unable to determine Flutter version.\n$error');
      return null;
    }
  }

  /// If this version of patchwing is on the `stable` branch, checks to see if
  /// there are newer commits available. If there are, prints a message to the
  /// user telling them to run `patchwing upgrade`.
  Future<void> _checkForUpdates() async {
    try {
      if (await patchwingVersion.isTrackingStable() &&
          !await patchwingVersion.isLatest()) {
        logger
          ..info('')
          ..info('A new version of patchwing is available!')
          ..info('Run ${lightCyan.wrap('patchwing upgrade')} to upgrade.');
      }
    } on Exception catch (error) {
      logger.detail('Unable to check for updates.\n$error');
    }
  }
}
