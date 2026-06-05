import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:patchwing_cli/src/cache.dart';
import 'package:patchwing_cli/src/code_push_client_wrapper.dart';
import 'package:patchwing_cli/src/common_arguments.dart';
import 'package:patchwing_cli/src/config/config.dart';
import 'package:patchwing_cli/src/doctor.dart';
import 'package:patchwing_cli/src/engine_manager.dart';
import 'package:patchwing_cli/src/executables/executables.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform/platform.dart';
import 'package:patchwing_cli/src/pubspec_editor.dart';
import 'package:patchwing_cli/src/patchwing_command.dart';
import 'package:patchwing_cli/src/patchwing_documentation.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_flutter.dart';
import 'package:patchwing_cli/src/patchwing_validator.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// {@template init_command}
///
/// `patchwing init`
/// Initialize Patchwing.
/// {@endtemplate}
class InitCommand extends PatchwingCommand {
  /// {@macro init_command}
  InitCommand() {
    argParser
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Initialize the app even if a "patchwing.yaml" already exists.',
        negatable: false,
      )
      ..addOption(
        'display-name',
        help:
            'The app name shown in the Patchwing dashboard '
            '(defaults to the package name in pubspec.yaml). '
            'Must be between 1 and '
            '${CommonArguments.appDisplayNameMaxLength} characters.',
      )
      ..addOption('organization-id', help: 'The organization ID to use.');
  }

  @override
  String get description => 'Initialize Patchwing.';

  @override
  String get name => 'init';

  @override
  Future<int> run() async {
    try {
      await patchwingValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    // ─── 环境初始化：确保 Flutter SDK、Engine、Patch 工具就绪 ───
    final envSetupResult = await _ensureEnvironment();
    if (envSetupResult != ExitCode.success.code) {
      return envSetupResult;
    }

    try {
      if (!patchwingEnv.hasPubspecYaml) {
        logger.err('''
Could not find a "pubspec.yaml".
Please make sure you are running "patchwing init" from within your Flutter project.
''');
        return ExitCode.noInput.code;
      }
    } on Exception catch (error) {
      logger.err('Error parsing "pubspec.yaml": $error');
      return ExitCode.software.code;
    }

    final organizationMemberships = await codePushClientWrapper
        .getOrganizationMemberships();
    if (organizationMemberships.isEmpty) {
      logger.err(
        '''You do not have any organizations. This should never happen. Please contact us on Discord or send us an email at contact@patchwing.dev.''',
      );
      return ExitCode.software.code;
    }

    final Organization organization;
    final orgIdArg = results['organization-id'] as String?;
    if (orgIdArg != null) {
      final orgId = int.tryParse(orgIdArg);
      if (orgId == null) {
        logger.err('Invalid organization ID: "$orgIdArg"');
        return ExitCode.usage.code;
      }

      final organizationMembership = organizationMemberships.firstWhereOrNull(
        (o) => o.organization.id == orgId,
      );
      if (organizationMembership == null) {
        logger.err('Organization with ID "$orgId" not found.');
        _logAvailableOrganizations(organizationMemberships);
        return ExitCode.usage.code;
      }
      organization = organizationMembership.organization;
    } else if (organizationMemberships.length > 1) {
      if (!patchwingEnv.canAcceptUserInput) {
        logger.err(
          'Multiple organizations found. '
          'Use --organization-id to specify one:',
        );
        _logAvailableOrganizations(organizationMemberships);
        return ExitCode.usage.code;
      }
      organization = logger.chooseOne(
        'Which organization should this app belong to?',
        choices: organizationMemberships.map((o) => o.organization).toList(),
        display: (o) => o.name,
        hint:
            'Pass --organization-id=<id> to select an organization without '
            'prompting.',
      );
    } else {
      organization = organizationMemberships.first.organization;
    }

    final force = results['force'] == true;

    Set<String>? androidFlavors;
    Set<String>? iosFlavors;
    Set<String>? macosFlavors;
    var productFlavors = <String>{};
    final projectRoot = patchwingEnv.getFlutterProjectRoot()!;
    final initializeGradleProgress = logger.progress('Initializing gradlew');
    final bool shouldStartGradleDaemon;
    try {
      shouldStartGradleDaemon = await _shouldStartGradleDaemon(
        projectRoot.path,
      );
    } on Exception catch (e, stackTrace) {
      initializeGradleProgress.fail();
      logger.err('Unable to initialize gradlew.');
      logger.err('Error: $e');
      logger.err('StackTrace: $stackTrace');
      return ExitCode.software.code;
    }
    initializeGradleProgress.complete();

    if (shouldStartGradleDaemon) {
      try {
        await gradlew.startDaemon(projectRoot.path);
      } on Exception {
        logger.err('Unable to start gradle daemon.');
        return ExitCode.software.code;
      }
    }

    final detectFlavorsProgress = logger.progress('Detecting product flavors');
    try {
      androidFlavors = await _maybeGetAndroidFlavors(projectRoot.path);
      iosFlavors = apple.flavors(platform: ApplePlatform.ios);
      macosFlavors = apple.flavors(platform: ApplePlatform.macos);
      productFlavors = <String>{
        if (androidFlavors != null) ...androidFlavors,
        if (iosFlavors != null) ...iosFlavors,
        if (macosFlavors != null) ...macosFlavors,
      };
      if (productFlavors.isEmpty) {
        detectFlavorsProgress.complete('No product flavors detected.');
      } else {
        detectFlavorsProgress.complete(
          '${productFlavors.length} product flavors detected:',
        );
        for (final flavor in productFlavors) {
          logger.info('  - $flavor');
        }
      }
    } on Exception catch (error) {
      detectFlavorsProgress.fail();
      logger.err('Unable to extract product flavors.\n$error');
      return ExitCode.software.code;
    }

    final patchwingYaml = patchwingEnv.getPatchwingYaml();
    final existingFlavors = patchwingYaml?.flavors;
    Set<String> newFlavors;
    if (existingFlavors != null) {
      final existingFlavorNames = existingFlavors.keys.toSet();
      newFlavors = productFlavors.difference(existingFlavorNames);
    } else if (patchwingYaml != null) {
      // Existing patchwing.yaml without flavors — treat all detected flavors
      // as new so they can be added without resetting the base app_id.
      newFlavors = productFlavors;
    } else {
      newFlavors = {};
    }

    // New flavors not being empty means that there is already an existing app
    // and we just need to add the new flavor entries.
    // If the --force flag is present, we will completely reinit the app and
    // don't care about which flavors are new.
    if (!force && newFlavors.isNotEmpty) {
      logger.info('New flavors detected: ${newFlavors.join(', ')}');
      final updatePatchwingYamlProgress = logger.progress(
        'Adding flavors to patchwing.yaml',
      );

      final AppMetadata existingApp;
      try {
        existingApp = await codePushClientWrapper.getApp(
          appId: patchwingYaml!.appId,
        );
      } on Exception catch (e) {
        updatePatchwingYamlProgress.fail('Failed to get existing app info: $e');
        return ExitCode.software.code;
      }

      final deflavoredAppName = existingApp.displayName
          .replaceAll(RegExp(r'\(.*\)'), '')
          .trim();
      final flavorsToAppIds = patchwingYaml.flavors ?? {};
      for (final flavor in newFlavors) {
        final app = await codePushClientWrapper.createApp(
          appName: '$deflavoredAppName ($flavor)',
          organizationId: organization.id,
        );
        flavorsToAppIds[flavor] = app.id;
      }
      _addPatchwingYamlToProject(
        projectRoot: projectRoot,
        appId: patchwingYaml.appId,
        flavors: flavorsToAppIds,
      );
      updatePatchwingYamlProgress.complete('Flavors added to patchwing.yaml');
      return ExitCode.success.code;
    }

    if (!force && patchwingEnv.hasPatchwingYaml) {
      logger
        ..err('A "patchwing.yaml" file already exists and seems up-to-date.')
        ..info(
          '''If you want to reinitialize Patchwing, please run ${lightCyan.wrap('patchwing init --force')}.''',
        );
      return ExitCode.software.code;
    }

    final String appId;
    Map<String, String>? flavors;
    try {
      final needsConfirmation = !force && patchwingEnv.canAcceptUserInput;
      final pubspecName = patchwingEnv.getPubspecYaml()!.name;
      var displayName = results['display-name'] as String?;
      displayName ??= needsConfirmation
          ? logger.prompt(
              '${lightGreen.wrap('?')} How should we refer to this app?',
              defaultValue: pubspecName,
              hint:
                  'Pass --display-name=<name> to set the app name without '
                  'prompting.',
            )
          : pubspecName;
      if (displayName.isEmpty ||
          displayName.length > CommonArguments.appDisplayNameMaxLength) {
        logger.err(
          'App display name must be between 1 and '
          '${CommonArguments.appDisplayNameMaxLength} characters.',
        );
        return ExitCode.usage.code;
      }
      final hasNoFlavors = productFlavors.isEmpty;
      final hasSomeFlavors =
          productFlavors.isNotEmpty &&
          ((androidFlavors?.isEmpty ?? false) ||
              (iosFlavors?.isEmpty ?? false));

      if (hasNoFlavors) {
        // No platforms have any flavors so we just create a single app
        // and assign it as the default.
        final app = await codePushClientWrapper.createApp(
          appName: displayName,
          organizationId: organization.id,
        );
        appId = app.id;
      } else if (hasSomeFlavors) {
        // Some platforms have flavors and some do not so we create an app
        // for the default (no flavor) and then create an app per flavor.
        final app = await codePushClientWrapper.createApp(
          appName: displayName,
          organizationId: organization.id,
        );
        appId = app.id;
        final values = <String, String>{};
        for (final flavor in productFlavors) {
          final app = await codePushClientWrapper.createApp(
            appName: '$displayName ($flavor)',
            organizationId: organization.id,
          );
          values[flavor] = app.id;
        }
        flavors = values;
      } else {
        // All platforms have flavors so we create an app per flavor
        // and assign the default to the first flavor.
        final values = <String, String>{};
        for (final flavor in productFlavors) {
          final app = await codePushClientWrapper.createApp(
            appName: '$displayName ($flavor)',
            organizationId: organization.id,
          );
          values[flavor] = app.id;
        }
        flavors = values;
        appId = flavors.values.first;
      }
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    _addPatchwingYamlToProject(
      projectRoot: projectRoot,
      appId: appId,
      flavors: flavors,
    );

    if (!patchwingEnv.pubspecContainsPatchwingYaml) {
      pubspecEditor.addPatchwingYamlToPubspecAssets();
    }

    logger.info(
      '''

${lightGreen.wrap('🐦 Patchwing initialized successfully!')}

✅ A patchwing app has been created.
✅ A "patchwing.yaml" has been created.
✅ The "pubspec.yaml" has been updated to include "patchwing.yaml" as an asset.

Reference the following commands to get started:

📦 To create a new release use: "${lightCyan.wrap('patchwing release')}".
🚀 To push an update use: "${lightCyan.wrap('patchwing patch')}".
👀 To preview a release use: "${lightCyan.wrap('patchwing preview')}".

For more information about Patchwing, visit ${link(uri: Uri.parse('https://patchwing.dev'))}''',
    );

    await doctor.runValidators(
      doctor.initAndDoctorValidators,
      applyFixes: true,
    );

    return ExitCode.success.code;
  }

  Future<bool> _shouldStartGradleDaemon(String projectPath) async {
    try {
      final isAvailable = await gradlew.isDaemonAvailable(projectPath);
      return !isAvailable;
    } on MissingAndroidProjectException {
      return false;
    }
  }

  Future<Set<String>?> _maybeGetAndroidFlavors(String projectPath) async {
    try {
      return await gradlew.productFlavors(projectPath);
    } on MissingAndroidProjectException {
      return null;
    }
  }

  PatchwingYaml _addPatchwingYamlToProject({
    required String appId,
    required Directory projectRoot,
    Map<String, String>? flavors,
  }) {
    const content =
        '''
# This file is used to configure the Patchwing updater used by your app.
# Learn more at $docsUrl
# This file does not contain any sensitive information and should be checked into version control.

# Your app_id is the unique identifier assigned to your app.
# It is used to identify your app when requesting patches from Patchwing's servers.
# It is not a secret and can be shared publicly.
app_id:

# auto_update controls if Patchwing should automatically update in the background on launch.
# If auto_update: false, you will need to use package:patchwing_code_push to trigger updates.
# https://pub.dev/packages/patchwing_code_push
# Uncomment the following line to disable automatic updates.
# auto_update: false
''';

    final editor = YamlEditor(content)..update(['app_id'], appId);

    if (flavors != null) editor.update(['flavors'], flavors);

    patchwingEnv
        .getPatchwingYamlFile(cwd: projectRoot)
        .writeAsStringSync(editor.toString());

    return PatchwingYaml(appId: appId);
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

  /// 确保开发环境就绪：Flutter SDK、Engine artifact、Patch 工具。
  /// 模仿 shorebird init 的环境初始化流程。
  Future<int> _ensureEnvironment() async {
    logger.info('\n🔧 正在检查开发环境...');

    // 1. 确保 Flutter SDK 已安装
    try {
      final revision = patchwingEnv.flutterRevision;
      final flutterDir = patchwingEnv.flutterDirectory;
      if (!flutterDir.existsSync()) {
        logger.info('  📦 Flutter SDK 未安装，正在下载...');
        await patchwingFlutter.installRevision(revision: revision);
        logger.info('  ✅ Flutter SDK 安装完成');
      } else {
        logger.info('  ✅ Flutter SDK 已就绪');
      }
    } on CacheCorruptedException catch (e) {
      logger.err('Flutter SDK 安装失败: $e');
      logger.info(
        '请运行 "pw cache clean" 清理缓存后重试。',
      );
      return ExitCode.software.code;
    } on Exception catch (e) {
      logger.err('Flutter SDK 安装失败: $e');
      return ExitCode.software.code;
    }

    // 2. 确保 Engine artifact 已下载
    try {
      final engineDir = await engineManager.ensureEngine();
      if (engineDir != null) {
        logger.info('  ✅ Engine artifact 已就绪');
      } else {
        logger.err(
          '  ✗ Engine artifact 下载失败。\n'
          '    请确认 CDN 上已上传对应版本的 engine artifact。\n'
          '    上传方法: bash scripts/package_engine.sh --upload',
        );
        return ExitCode.software.code;
      }
    } on Exception catch (e) {
      logger.err('Engine artifact 准备失败: $e');
      return ExitCode.software.code;
    }

    // 3. 确保 Patch 工具已下载
    try {
      await cache.updateAll();
      logger.info('  ✅ Patch 工具已就绪');
    } on CacheUpdateFailure catch (e) {
      logger.err('Patch 工具下载失败: $e');
      return ExitCode.software.code;
    } on Exception catch (e) {
      logger.err('Patch 工具准备失败: $e');
      return ExitCode.software.code;
    }

    logger.info('  🎉 开发环境检查完成！\n');
    return ExitCode.success.code;
  }
}
