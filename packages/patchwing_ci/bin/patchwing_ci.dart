// cspell:words sysexits
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:patchwing_ci/src/patchwing_ci_command_runner.dart';

Future<void> main(List<String> args) async {
  try {
    exit(await PatchwingCiCommandRunner().run(args) ?? 0);
  } on UsageException catch (e) {
    // Bad CLI args. Print the message + usage and exit 64 (EX_USAGE
    // per sysexits.h) instead of dumping a Dart stack trace.
    stderr.writeln(e);
    exit(64);
  }
}
