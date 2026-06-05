import 'package:patchwing_cli/src/pubspec_editor.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/validators/validators.dart';

/// Verifies that the patchwing.yaml is found in pubspec.yaml assets.
class PatchwingYamlAssetValidator extends Validator {
  @override
  String get description => 'patchwing.yaml found in pubspec.yaml assets';

  @override
  bool canRunInCurrentContext() => patchwingEnv.hasPubspecYaml;

  @override
  String get incorrectContextMessage => '''
The pubspec.yaml file does not exist.
The command you are running must be run within a Flutter app project.''';

  @override
  Future<List<ValidationIssue>> validate() async {
    if (!canRunInCurrentContext()) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'No pubspec.yaml file found',
        ),
      ];
    }

    if (patchwingEnv.pubspecContainsPatchwingYaml) {
      return [];
    }

    return [
      ValidationIssue(
        severity: ValidationIssueSeverity.error,
        message: 'No patchwing.yaml found in pubspec.yaml assets',
        fix: () => pubspecEditor.addPatchwingYamlToPubspecAssets(),
      ),
    ];
  }
}
