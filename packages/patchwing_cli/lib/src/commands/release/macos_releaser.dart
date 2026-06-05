import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:patchwing_cli/src/artifact_builder/artifact_builder.dart';
import 'package:patchwing_cli/src/artifact_manager.dart';
import 'package:patchwing_cli/src/code_push_client_wrapper.dart';
import 'package:patchwing_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:patchwing_cli/src/commands/release/release.dart';
import 'package:patchwing_cli/src/doctor.dart';
import 'package:patchwing_cli/src/extensions/arg_results.dart';
import 'package:patchwing_cli/src/logging/patchwing_logger.dart';
import 'package:patchwing_cli/src/platform/platform.dart';
import 'package:patchwing_cli/src/release_type.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:patchwing_cli/src/validators/validators.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';

/// {@template macos_releaser}
/// Functions to build and publish a macOS release.
/// {@endtemplate}
class MacosReleaser extends Releaser with AppleReleaserMixin {
  /// {@macro macos_releaser}
  MacosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// Whether to codesign the release.
  bool get codesign => argResults['codesign'] == true;

  @override
  ReleaseType get releaseType => ReleaseType.macos;

  @override
  String get supplementPlatformSubdir => 'macos';

  @override
  String get supplementArtifactArch => 'macos_supplement';

  @override
  String get artifactDisplayName => 'macOS app';

  @override
  List<Validator> get applePlatformValidators => doctor.macosCommandValidators;

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();
    await assertObfuscationIsSupported();
  }

  @override
  Version? get minimumFlutterVersion => minimumSupportedMacosFlutterVersion;

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!codesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''patchwing preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        );
    }

    final base64PublicKey = await getEncodedPublicKey();

    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);

    await artifactBuilder.buildMacos(
      codesign: codesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: base64PublicKey,
      ddMaxBytes: ddMaxBytes,
    );

    verifyObfuscationMap();

    final appDirectory = artifactManager.getMacOSAppDirectory(flavor: flavor);
    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    return appDirectory;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    final plistFile = File(
      p.join(releaseArtifactRoot.path, 'Contents', 'Info.plist'),
    );
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return Plist(file: plistFile).versionNumber;
    } on Exception catch (error) {
      logger.err(
        '''Failed to determine release version from ${plistFile.path}: $error''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final appDirectory = artifactManager.getMacOSAppDirectory(flavor: flavor);
    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    await codePushClientWrapper.createMacosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      appPath: appDirectory.path,
      isCodesigned: codesign,
      podfileLockHash: patchwingEnv.macosPodfileLockHash,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions =>
      '''

macOS app created at ${artifactManager.getMacOSAppDirectory(flavor: flavor)!.path}.

${styleBold.wrap('Note:')} If you distribute your app via the Mac App Store using a .pkg installer, the packaging process may modify the binary and cause patch failures. See ${link(uri: Uri.parse('https://github.com/patchwingtech/patchwing/issues/3223'))} for more information.
''';
}
