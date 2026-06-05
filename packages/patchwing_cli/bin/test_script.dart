import 'dart:io';
import 'package:path/path.dart' as p;

void main() {
  final script = Platform.script.toFilePath();
  final resolved = Platform.resolvedExecutable;
  print('Platform.script: $script');
  print('Platform.resolvedExecutable: $resolved');

  final scriptFile = File(script);
  print('script .parent.parent.parent: ${scriptFile.parent.parent.parent}');

  final resolvedFile = File(resolved);
  print('resolved .parent.parent.parent: ${resolvedFile.parent.parent.parent}');
}
