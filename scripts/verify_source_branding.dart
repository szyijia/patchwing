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

  if (failures.isNotEmpty) {
    stderr
      ..writeln('Patchwing source branding verification failed:')
      ..writeln(failures.join('\n'));
    exitCode = 1;
    return;
  }

  stdout.writeln('Patchwing source branding verification passed.');
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
