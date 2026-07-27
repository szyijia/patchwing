import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';

final _shorebird = RegExp('shorebird', caseSensitive: false);
final _shorebirdUrl = RegExp(
  r'https?://[^\s]*shorebird|github\.com/shorebirdtech',
  caseSensitive: false,
);
final _legacyPatchwingCdn = RegExp(
  r'cdn\.patchwing\.net/patchwing(?:[\s\x27\x22;]|$)',
  caseSensitive: false,
);

void main() {
  final repository = File(Platform.script.toFilePath()).parent.parent;
  final sourceRoot = Directory(
    '${repository.path}/packages/shorebird_cli/lib',
  );
  final failures = <String>[];

  for (final entity in sourceRoot.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final unit = parseFile(
      path: entity.path,
      featureSet: FeatureSet.latestLanguageVersion(),
    ).unit;
    unit.accept(_StringVisitor(entity.path, failures));
  }

  _checkBootstrapScripts(repository, failures);

  if (failures.isNotEmpty) {
    stderr
      ..writeln('Patchwing source branding verification failed:')
      ..writeln(failures.join('\n'));
    exitCode = 1;
    return;
  }

  stdout.writeln('Patchwing source branding verification passed.');
}

void _checkBootstrapScripts(Directory repository, List<String> failures) {
  const relativePaths = [
    'third_party/flutter/bin/internal/shared.sh',
    'bin/shorebird',
    'bin/shorebird.ps1',
    'bin/shorebird.bat',
    'bin/pw',
    'bin/pw.bat',
  ];

  for (final relativePath in relativePaths) {
    final file = File('${repository.path}/$relativePath');
    final lines = file.readAsLinesSync();
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('#') || trimmed.toUpperCase().startsWith('REM ')) {
        continue;
      }

      final productSurface = line.replaceAll(
        RegExp(r'\$\{?SHOREBIRD_[A-Z0-9_]+\}?'),
        '',
      );
      final visibleShorebird = RegExp(
        r'(?:echo|printf|Write-(?:Output|Debug|Error))[^\n]*shorebird',
        caseSensitive: false,
      ).hasMatch(productSurface);
      if (_shorebirdUrl.hasMatch(productSurface) ||
          _legacyPatchwingCdn.hasMatch(productSurface) ||
          visibleShorebird) {
        failures.add('${file.path}:${index + 1}: ${line.trim()}');
      }
    }
  }
}

class _StringVisitor extends RecursiveAstVisitor<void> {
  _StringVisitor(this.path, this.failures);

  final String path;
  final List<String> failures;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _check(node.value, node.offset);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    final literalText = node.elements
        .whereType<InterpolationString>()
        .map((element) => element.value)
        .join(r'${...}');
    _check(literalText, node.offset);
    super.visitStringInterpolation(node);
  }

  void _check(String value, int offset) {
    final productSurface = value
        .replaceAll('package:shorebird_code_push', '')
        .replaceAll('ShorebirdFlutter.framework', '');
    if (!_shorebird.hasMatch(productSurface)) return;

    // Internal package names, protocol keys, flags, paths, and artifact names
    // contain no whitespace and must remain byte-compatible with upstream.
    // URLs and human-readable prose are product surface and must be Patchwing.
    if (!_shorebirdUrl.hasMatch(productSurface) &&
        !RegExp(r'\s').hasMatch(productSurface)) {
      return;
    }

    final line = File(
      path,
    ).readAsStringSync().substring(0, offset).split('\n').length;
    final preview = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    failures.add('$path:$line: $preview');
  }
}
