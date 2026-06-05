import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_version.dart';

/// {@template upgrade_command}
/// `patchwing upgrade`
///
/// Patchwing 的 `pw` 是预编译二进制（通过 `install.sh` 从 CDN 下载安装），
/// 不再支持 in-place 升级，本命令仅做版本检查并提示用户重新运行
/// `install.sh` 来获取最新版本。
/// {@endtemplate}
class UpgradeCommand extends PatchwingCommand {
  /// {@macro upgrade_command}
  UpgradeCommand();

  @override
  String get description => 'Upgrade your copy of Patchwing.';

  /// Name of the command, exposed for the [CommandRunner].
  static const String commandName = 'upgrade';

  @override
  String get name => commandName;

  /// 平台相关的安装命令，提示给用户。
  String get _reinstallHint {
    if (Platform.isWindows) {
      return 'iwr -useb https://www.patchwing.net/install.ps1 | iex';
    }
    return 'curl -fsSL https://www.patchwing.net/install.sh | bash';
  }

  @override
  Future<int> run() async {
    final updateCheckProgress = logger.progress('Checking for updates');

    late final String currentVersion;
    try {
      currentVersion = await patchwingVersion.fetchCurrentVersion();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Fetching current version failed: ${error.message}');
      return ExitCode.software.code;
    }

    late final String latestVersion;
    try {
      latestVersion = await patchwingVersion.fetchLatestVersion();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Checking for updates failed: ${error.message}');
      return ExitCode.software.code;
    }

    updateCheckProgress.complete('Checked for updates');

    if (currentVersion == 'dev') {
      logger.info(
        'Running a dev build of patchwing; skipping upgrade '
        '(latest published: $latestVersion).',
      );
      return ExitCode.success.code;
    }

    if (currentVersion == latestVersion) {
      logger.info('Patchwing is already at the latest version.');
      return ExitCode.success.code;
    }

    logger
      ..info('')
      ..info('A new version of patchwing is available!')
      ..info('  current: $currentVersion')
      ..info('  latest:  $latestVersion')
      ..info('')
      ..info(
        'Patchwing 是预编译二进制分发，请重新运行安装脚本完成升级：',
      )
      ..info('  ${lightCyan.wrap(_reinstallHint)}');

    return ExitCode.success.code;
  }
}
