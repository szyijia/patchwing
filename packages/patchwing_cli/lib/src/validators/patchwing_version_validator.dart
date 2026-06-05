import 'dart:io';

import 'package:patchwing_cli/src/patchwing_version.dart';
import 'package:patchwing_cli/src/validators/validators.dart';

/// Verifies that the currently installed version of Patchwing is the latest.
class PatchwingVersionValidator extends Validator {
  /// Creates a new [PatchwingVersionValidator].
  PatchwingVersionValidator();

  @override
  String get description => 'Patchwing is up-to-date';

  @override
  Future<List<ValidationIssue>> validate() async {
    final bool isPatchwingUpToDate;

    try {
      isPatchwingUpToDate = await patchwingVersion.isLatest();
    } on ProcessException catch (e) {
      return [
        ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'Failed to get patchwing version. Error: ${e.message}',
        ),
      ];
    }

    if (!isPatchwingUpToDate) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.warning,
          message: '''
A new version of patchwing is available! Run `patchwing upgrade` to upgrade.''',
        ),
      ];
    }

    return [];
  }
}
