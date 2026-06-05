import 'dart:async';

import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';

/// {@template flutter_config_command}
/// `patchwing flutter config`
/// Manage your Patchwing Flutter Config.
/// {@endtemplate}
class FlutterConfigCommand extends PatchwingProxyCommand {
  @override
  String get description =>
      '''Configure Flutter settings. This proxies to the underlying `flutter config` command.''';

  @override
  String get name => 'config';

  @override
  FutureOr<int> run() => process.stream('flutter', ['config', ...results.rest]);
}
