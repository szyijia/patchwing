import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/code_push_client_wrapper.dart';
import 'package:patchwing_cli/src/common_arguments.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';

/// `patchwing apps create`
class AppsCreateCommand extends PatchwingCommand {
  /// Creates an apps create command.
  AppsCreateCommand() {
    argParser
      ..addOption(
        'display-name',
        help:
            'The app name shown in the Patchwing dashboard. Must be between '
            '1 and ${CommonArguments.appDisplayNameMaxLength} characters.',
      )
      ..addOption('organization-id', help: 'The organization ID to use.');
  }

  @override
  String get name => 'create';

  @override
  String get description {
    final jsonHint = PatchwingCommand.jsonHint(
      'patchwing apps create --display-name MyApp --json',
    );
    return 'Create a Patchwing app record without creating a Flutter '
        'project.\n\n'
        '$jsonHint';
  }

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (error) {
      return error.exitCode.code;
    }

    final organizationMemberships = await codePushClientWrapper
        .getOrganizationMemberships();
    if (organizationMemberships.isEmpty) {
      logger.err(
        'You do not have any organizations. Please create an account at '
        'https://console.patchwing.net first.',
      );
      return ExitCode.software.code;
    }

    final organization = _resolveOrganization(organizationMemberships);
    if (organization == null) return ExitCode.usage.code;

    final displayName = _resolveDisplayName();
    if (displayName == null) return ExitCode.usage.code;

    final app = await codePushClientWrapper.createApp(
      organizationId: organization.id,
      appName: displayName,
    );

    if (isJsonMode) {
      emitJsonSuccess({
        'app_id': app.id,
        'display_name': app.displayName,
        'organization_id': organization.id,
      });
    } else {
      logger
        ..info('✅ A Patchwing app has been created.')
        ..info('app_id: ${lightCyan.wrap(app.id)}')
        ..info('display_name: ${lightCyan.wrap(app.displayName)}');
    }

    return ExitCode.success.code;
  }

  Organization? _resolveOrganization(
    List<OrganizationMembership> organizationMemberships,
  ) {
    final orgIdArg = results['organization-id'] as String?;
    if (orgIdArg != null) {
      final orgId = int.tryParse(orgIdArg);
      if (orgId == null) {
        logger.err('Invalid organization ID: "$orgIdArg"');
        return null;
      }

      final organizationMembership = organizationMemberships.firstWhereOrNull(
        (o) => o.organization.id == orgId,
      );
      if (organizationMembership == null) {
        logger.err('Organization with ID "$orgId" not found.');
        _logAvailableOrganizations(organizationMemberships);
        return null;
      }
      return organizationMembership.organization;
    }

    if (organizationMemberships.length > 1) {
      if (!patchwingEnv.canAcceptUserInput) {
        logger.err(
          'Multiple organizations found. Use --organization-id to specify one:',
        );
        _logAvailableOrganizations(organizationMemberships);
        return null;
      }
      return logger.chooseOne(
        'Which organization should this app belong to?',
        choices: organizationMemberships.map((o) => o.organization).toList(),
        display: (o) => o?.name ?? '',
        hint:
            'Pass --organization-id=<id> to select an organization without '
            'prompting.',
      );
    }

    return organizationMemberships.first.organization;
  }

  String? _resolveDisplayName() {
    var displayName = results['display-name'] as String?;
    if (displayName == null) {
      if (!patchwingEnv.canAcceptUserInput) {
        logger.err('Missing required option: --display-name');
        return null;
      }
      displayName = logger.prompt(
        '${lightGreen.wrap('?')} How should we refer to this app?',
        hint:
            'Pass --display-name=<name> to set the app name without prompting.',
      );
    }

    if (displayName.isEmpty ||
        displayName.length > CommonArguments.appDisplayNameMaxLength) {
      logger.err(
        'App display name must be between 1 and '
        '${CommonArguments.appDisplayNameMaxLength} characters.',
      );
      return null;
    }

    return displayName;
  }

  void _logAvailableOrganizations(
    List<OrganizationMembership> memberships,
  ) {
    logger.info('Available organizations:');
    for (final membership in memberships) {
      final org = membership.organization;
      logger.info('  ${org.name} (id: ${org.id})');
    }
  }
}
