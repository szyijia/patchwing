import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_flutter.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';

/// {@template patchwing_create_command}
/// `patchwing create`
/// Create a new Flutter app with Patchwing.
/// {@endtemplate}
class CreateCommand extends PatchwingProxyCommand {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a new Flutter project with Patchwing.';

  /// 这些参数会被从 `results.rest` 中抽出来转交给后续的 `pw init`，
  /// 而不会传给 `flutter create`（flutter create 不认识它们）。
  ///
  /// - `--display-name` / `--display-name=<name>`: 应用展示名，避免 init
  ///   交互式提示 "How should we refer to this app?"。
  /// - `--organization-id` / `--organization-id=<id>`: 选择组织，避免 init
  ///   在多组织时弹出 chooseOne 提示。
  /// - `--force` / `-f`: 即使存在 patchwing.yaml 也强制重新初始化。
  static const _initOnlyOptions = {
    '--display-name',
    '--organization-id',
  };

  static const _initOnlyFlags = {
    '--force',
    '-f',
  };

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final raw = List<String>.from(results.rest);
    final initArgs = <String>[];
    final flutterArgs = <String>[];
    _splitArgs(raw, initArgs: initArgs, flutterArgs: flutterArgs);

    if (flutterArgs.isEmpty) {
      final appCreateArgs = initArgs
          .where((arg) => !_initOnlyFlags.contains(arg))
          .toList();
      if (appCreateArgs.isNotEmpty) {
        return runner!.run([
          if (isJsonMode) '--json',
          'apps',
          'create',
          ...appCreateArgs,
        ]);
      }
      logger.err(
        'No Flutter project output directory specified. '
        'Run "patchwing create <directory>" to create a project, or '
        '"patchwing apps create --display-name <name>" to create only an '
        'app record.',
      );
      return ExitCode.usage.code;
    }

    try {
      await patchwingFlutter.installRevision(
        revision: patchwingEnv.flutterRevision,
      );
    } on Exception {
      return ExitCode.software.code;
    }

    final createExitCode = await process.stream('flutter', [
      'create',
      ...flutterArgs,
    ]);

    if (createExitCode != ExitCode.success.code) {
      return createExitCode;
    }

    if (flutterArgs.contains('-h') || flutterArgs.contains('--help')) {
      return createExitCode;
    }

    // 项目根目录：取 flutterArgs 中第一个非 flag 实参作为项目目录名。
    final projectDir = flutterArgs.firstWhere(
      (a) => !a.startsWith('-'),
      orElse: () => '.',
    );

    return runScoped(
      () => runner!.run(['init', ...initArgs]),
      values: {
        patchwingEnvRef.overrideWith(
          () => PatchwingEnv(
            flutterProjectRootOverride: p.absolute(p.normalize(projectDir)),
          ),
        ),
      },
    );
  }

  /// 把 [raw] 拆成两份：[initArgs] 给后续 `pw init`，[flutterArgs] 给
  /// `flutter create`。同时支持 `--key value` 与 `--key=value` 两种写法。
  void _splitArgs(
    List<String> raw, {
    required List<String> initArgs,
    required List<String> flutterArgs,
  }) {
    for (var i = 0; i < raw.length; i++) {
      final arg = raw[i];

      // --key=value 形式
      final eqIdx = arg.indexOf('=');
      final key = eqIdx > 0 ? arg.substring(0, eqIdx) : arg;

      if (_initOnlyFlags.contains(key)) {
        initArgs.add(arg);
        continue;
      }

      if (_initOnlyOptions.contains(key)) {
        if (eqIdx > 0) {
          // --key=value：整段加入。
          initArgs.add(arg);
        } else if (i + 1 < raw.length) {
          // --key value：连同下一个值一起加入。
          initArgs
            ..add(arg)
            ..add(raw[i + 1]);
          i += 1;
        } else {
          // --key 后面没有值，原样保留（让 init 的 ArgParser 报错给用户）。
          initArgs.add(arg);
        }
        continue;
      }

      flutterArgs.add(arg);
    }
  }
}
