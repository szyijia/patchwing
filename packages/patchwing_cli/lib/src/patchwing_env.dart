import 'dart:convert';
import 'dart:io' hide Platform;
import 'dart:isolate';

import 'package:checked_yaml/checked_yaml.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/config/patchwing_yaml.dart';
import 'package:patchwing_cli/src/json_output.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_code_push_client/patchwing_code_push_client.dart';

/// Exception thrown when the Patchwing cache appears to be corrupted.
///
/// Surfaces a user-actionable message directing the user to run
/// `patchwing cache clean` and retry.
class CacheCorruptedException implements Exception {
  /// Creates a [CacheCorruptedException] explaining why the cache is
  /// considered corrupted via [reason] (a complete sentence).
  const CacheCorruptedException(this.reason);

  /// Human-readable explanation of why the cache is considered corrupted.
  final String reason;

  @override
  String toString() =>
      '$reason Your Patchwing installation may be corrupted. '
      "Try running 'patchwing cache clean' and retrying.";
}

/// A reference to a [PatchwingEnv] instance.
final patchwingEnvRef = create(PatchwingEnv.new);

/// The [PatchwingEnv] instance available in the current zone.
PatchwingEnv get patchwingEnv => read(patchwingEnvRef);

/// Scoped override for the `--storage-url` CLI flag.
///
/// `command_runner` 解析到 `--storage-url=...` 时，会通过 [runScoped] 把这个
/// ref 覆写为 CLI 传入值，[PatchwingEnv.storageBaseUri] 在解析时优先读取它。
/// 默认（未传 CLI 参数时）为 `null`，此时回落到 env / yaml / 内置默认。
final cliStorageUrlOverrideRef = create<String?>(() => null);

/// The CLI `--storage-url` override, or `null` if the flag was not provided.
///
/// 该 getter 在不存在 scoped 上下文（例如顶层 `dart run` 测试）时会安全回退
/// 到 `null`，避免抛 `read called in a scope which does not contain ...`。
String? get cliStorageUrlOverride {
  try {
    return read(cliStorageUrlOverrideRef);
  } on Object {
    // No scope active – treat as "user did not pass --storage-url".
    return null;
  }
}

/// {@template patchwing_env}
/// A class that provides access to patchwing environment metadata.
/// {@endtemplate}
class PatchwingEnv {
  /// {@macro patchwing_env}
  const PatchwingEnv({
    String? flutterRevisionOverride,
    String? flutterProjectRootOverride,
  }) : _flutterRevisionOverride = flutterRevisionOverride,
       _flutterProjectRootOverride = flutterProjectRootOverride;

  /// Copy the [PatchwingEnv] and optionally override the flutter revision.
  PatchwingEnv copyWith({String? flutterRevisionOverride}) => PatchwingEnv(
    flutterRevisionOverride:
        flutterRevisionOverride ?? _flutterRevisionOverride,
  );

  final String? _flutterRevisionOverride;
  final String? _flutterProjectRootOverride;

  /// The application config directory for the Patchwing CLI.
  ///
  /// Keep user-visible state under the Patchwing root (`~/.patchwing` for
  /// installed binaries) so cleanup, credentials, logs, and cache all live in
  /// one predictable tree.
  Directory get configDirectory {
    return patchwingRoot;
  }

  /// The directory where patchwing logs are stored.
  Directory get logsDirectory {
    return Directory(p.join(configDirectory.path, 'logs'));
  }

  /// The root directory of the Patchwing install.
  ///
  /// Can be overridden with PATCHWING_ROOT environment variable.
  Directory get patchwingRoot {
    final envRoot = platform.environment['PATCHWING_ROOT'];
    if (envRoot != null) {
      return Directory(envRoot);
    }

    final script = platform.script;
    final scriptPath = script.toFilePath();

    // Mode 1: `dart run` — script points to the source .dart file
    // e.g. /.../patchwing/packages/patchwing_cli/bin/patchwing.dart
    if (scriptPath.endsWith('packages/patchwing_cli/bin/patchwing.dart')) {
      return Directory(
        p.dirname(p.dirname(p.dirname(p.dirname(scriptPath)))),
      );
    }

    // Mode 2: snapshot execution — script points to .snapshot file
    // e.g. /.../patchwing/.dart_tool/pub/bin/patchwing_cli/patchwing.dart-3.11.3.snapshot
    // or   /.../patchwing/bin/patchwing.dart-3.11.3.snapshot
    final snapshotPattern = RegExp(r'patchwing\.dart-[\d.]+\.snapshot$');
    if (snapshotPattern.hasMatch(scriptPath)) {
      // .dart_tool/pub/bin/patchwing_cli/patchwing.dart-X.Y.Z.snapshot
      if (scriptPath.contains('.dart_tool/pub/bin/patchwing_cli/')) {
        final dartToolIndex = scriptPath.indexOf('.dart_tool');
        return Directory(scriptPath.substring(0, dartToolIndex - 1));
      }
      return Directory(p.dirname(p.dirname(scriptPath))); // up from bin/
    }

    // Mode 3: `dart pub global run` — script is a package: URI and
    // resolvedExecutable points to the Dart VM (not our binary).
    // We look up patchwing_cli's location via the package config.
    if (script.scheme == 'package') {
      try {
        final packageConfig = Isolate.packageConfigSync;
        if (packageConfig != null) {
          final configFile = File(packageConfig.toFilePath());
          if (configFile.existsSync()) {
            final config =
                jsonDecode(configFile.readAsStringSync())
                    as Map<String, dynamic>;
            final packages = config['packages'] as List<dynamic>?;
            for (final pkg in packages ?? <dynamic>[]) {
              final pkgMap = pkg as Map<String, dynamic>;
              if (pkgMap['name'] == 'patchwing_cli') {
                var rootUri = pkgMap['rootUri'] as String?;
                if (rootUri != null) {
                  late final Uri uri;
                  if (rootUri.startsWith('file:')) {
                    uri = Uri.parse(rootUri);
                  } else {
                    // Relative to package config directory
                    final configDir = configFile.parent.path;
                    uri = Uri.file(
                      p.normalize(p.join(configDir, rootUri)),
                    );
                  }
                  final pkgPath = uri.toFilePath();
                  // Navigate from packages/patchwing_cli up to patchwing root
                  return Directory(p.dirname(p.dirname(pkgPath)));
                }
              }
            }
          }
        }
      } catch (_) {}
    }

    // Mode 4: compiled executable — resolvedExecutable points to the
    // binary itself.
    final resolved = platform.resolvedExecutable;
    if (!resolved.contains('dart-sdk')) {
      // Mode 4a (用户安装): `~/.patchwing/bin/pw` —— 二进制位于 <root>/bin/pw，
      // root = bin 的父目录。这是 GitHub Release / install_patchwing.sh 的标准布局。
      final exe = File(resolved);
      if (p.basename(exe.parent.path) == 'bin') {
        return exe.parent.parent;
      }
      // Mode 4b (开发编译): packages/patchwing_cli/pw —— 沿用旧逻辑
      // 从 .../patchwing/packages/patchwing_cli/pw 向上 3 级到 patchwing root
      return exe.parent.parent.parent;
    }

    // Should not reach here in normal circumstances.
    return File(resolved).parent.parent.parent;
  }

  /// The Patchwing engine revision.
  /// 从 patchwingRoot/bin/internal/engine.version 读取。
  String get patchwingEngineRevision {
    final file = File(
      p.join(patchwingRoot.path, 'bin', 'internal', 'engine.version'),
    );
    try {
      return file.readAsStringSync().trim();
    } on FileSystemException {
      throw CacheCorruptedException('Could not read ${file.path}.');
    }
  }

  /// Get the Patchwing Flutter revision.
  String get flutterRevision {
    if (_flutterRevisionOverride != null) return _flutterRevisionOverride;
    final file = File(
      p.join(patchwingRoot.path, 'bin', 'internal', 'flutter.version'),
    );
    try {
      return file.readAsStringSync().trim();
    } on FileSystemException {
      throw CacheCorruptedException('Could not read ${file.path}.');
    }
  }

  /// Whether the project uses package:patchwing_code_push.
  bool get usesPatchwingCodePushPackage {
    final pubspec = getPubspecYaml();
    return pubspec?.dependencies.containsKey('patchwing_code_push') ?? false;
  }

  /// The root of the Patchwing-vended Flutter git checkout.
  ///
  /// 用户环境：`pw init` 时从 GitHub (szyijia/flutter.git) clone 到
  /// `<patchwingRoot>/bin/cache/flutter/<flutterRevision>/`。
  ///
  /// 开发环境：可通过 `PATCHWING_DEV_FLUTTER_DIR` 环境变量显式指向开发仓库的
  /// `vendor/flutter/`，跳过下载并直接使用本机魔改后的 SDK。
  /// 注意：不再有任何隐式 fallback——若环境变量未设且缓存目录不存在，
  /// 后续步骤会按用户环境流程报错并提示运行 `pw init`。
  Directory get flutterDirectory {
    final devOverride = platform.environment['PATCHWING_DEV_FLUTTER_DIR'];
    if (devOverride != null && devOverride.isNotEmpty) {
      return Directory(devOverride);
    }
    return Directory(
      p.join(patchwingRoot.path, 'bin', 'cache', 'flutter', flutterRevision),
    );
  }

  /// The Patchwing-vended Flutter binary.
  File get flutterBinaryFile {
    final flutter = platform.isWindows ? 'flutter.bat' : 'flutter';
    return File(p.join(flutterDirectory.path, 'bin', flutter));
  }

  /// The Patchwing-vended Dart binary.
  File get dartBinaryFile {
    final dart = platform.isWindows ? 'dart.bat' : 'dart';
    return File(p.join(flutterDirectory.path, 'bin', dart));
  }

  /// The Cocoapods lockfile for this project's iOS app.
  File get iosPodfileLockFile {
    return File(p.join(getFlutterProjectRoot()!.path, 'ios', 'Podfile.lock'));
  }

  /// The hash of the Podfile.lock file for this project's iOS app. Will be null
  /// if the file does not exist.
  String? get iosPodfileLockHash {
    if (!iosPodfileLockFile.existsSync()) return null;
    return sha256.convert(iosPodfileLockFile.readAsBytesSync()).toString();
  }

  /// The Cocoapods lockfile for this project's macOS app.
  File get macosPodfileLockFile {
    return File(p.join(getFlutterProjectRoot()!.path, 'macos', 'Podfile.lock'));
  }

  /// The hash of the Podfile.lock file for this project's macOS app. Will be
  /// null if the file does not exist.
  String? get macosPodfileLockHash {
    if (!macosPodfileLockFile.existsSync()) return null;
    return sha256.convert(macosPodfileLockFile.readAsBytesSync()).toString();
  }

  /// The build directory of the current patchwing project.
  Directory get buildDirectory {
    return Directory(p.join(getFlutterProjectRoot()!.path, 'build'));
  }

  /// Where the link supplement files are stored.
  // TODO(eseidel): Make this not iOS specific.
  Directory get iosSupplementDirectory =>
      Directory(p.join(buildDirectory.path, 'ios', 'patchwing'));

  /// The `patchwing.yaml` file for this project.
  File getPatchwingYamlFile({required Directory cwd}) {
    return File(p.join(cwd.path, 'patchwing.yaml'));
  }

  /// The `pubspec.yaml` file for this project.
  File getPubspecYamlFile({required Directory cwd}) {
    return File(p.join(cwd.path, 'pubspec.yaml'));
  }

  /// Finds nearest ancestor file
  /// relative to the [cwd] that satisfies [where].
  File? findNearestAncestor({
    required File? Function(String path) where,
    Directory? cwd,
  }) {
    Directory? prev;
    var dir = cwd ?? Directory.current;
    while (prev?.path != dir.path) {
      final file = where(dir.path);
      if (file?.existsSync() ?? false) return file;
      prev = dir;
      dir = dir.parent;
    }
    return null;
  }

  /// Returns the root directory of the nearest Patchwing project.
  Directory? getPatchwingProjectRoot() {
    final file = findNearestAncestor(
      where: (path) => getPatchwingYamlFile(cwd: Directory(path)),
    );
    if (file == null || !file.existsSync()) return null;
    return Directory(p.dirname(file.path));
  }

  /// Returns the root directory of the nearest Flutter project.
  Directory? getFlutterProjectRoot() {
    if (_flutterProjectRootOverride != null) {
      return Directory(_flutterProjectRootOverride);
    }
    final file = findNearestAncestor(
      where: (path) => getPubspecYamlFile(cwd: Directory(path)),
    );
    if (file == null || !file.existsSync()) return null;
    return Directory(p.dirname(file.path));
  }

  /// The `patchwing.yaml` file for this project, parsed into a [PatchwingYaml]
  /// object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  PatchwingYaml? getPatchwingYaml() {
    final root = getPatchwingProjectRoot();
    if (root == null) return null;
    final yaml = getPatchwingYamlFile(cwd: root).readAsStringSync();
    return checkedYamlDecode(yaml, (m) => PatchwingYaml.fromJson(m!));
  }

  /// The `pubspec.yaml` file for this project, parsed into a [Pubspec] object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  Pubspec? getPubspecYaml() {
    final root = getFlutterProjectRoot();
    if (root == null) return null;
    try {
      final yaml = getPubspecYamlFile(cwd: root).readAsStringSync();
      return Pubspec.parse(yaml, lenient: true);
    } on Exception {
      return null;
    }
  }

  /// Whether the current project has a `patchwing.yaml` file.
  bool get hasPatchwingYaml => getPatchwingYaml() != null;

  /// Whether the current project has a `pubspec.yaml` file.
  bool get hasPubspecYaml => getPubspecYaml() != null;

  /// Whether the current project's `pubspec.yaml` file contains a reference to
  /// `patchwing.yaml` in its `assets` section.
  bool get pubspecContainsPatchwingYaml {
    final pubspec = getPubspecYaml();
    if (pubspec == null) return false;
    if (pubspec.flutter == null) return false;
    if (pubspec.flutter!['assets'] == null) return false;
    final assets = pubspec.flutter!['assets'] as List;
    return assets.contains('patchwing.yaml');
  }

  /// Returns the Android package name from the pubspec.yaml file of a Flutter
  /// module.
  String? get androidPackageName {
    final pubspec = getPubspecYaml();
    final module = pubspec?.flutter?['module'] as Map?;
    return module?['androidPackage'] as String?;
  }

  /// The base URL for the Patchwing auth service. Can be overridden with the
  /// `AUTH_SERVICE_URL` environment variable.
  /// TODO(patchwing): Configure your own auth service host
  Uri get authServiceUri => Uri.parse(
    platform.environment['AUTH_SERVICE_URL'] ?? 'https://auth.patchwing.net',
  );

  /// The expected JWT issuer for Patchwing-issued tokens. Can be overridden
  /// with the `PATCHWING_JWT_ISSUER` environment variable.
  /// TODO(patchwing): Configure your own JWT issuer
  String get jwtIssuer =>
      platform.environment['PATCHWING_JWT_ISSUER'] ??
      'https://auth.patchwing.net';

  /// The base URL for the Patchwing code push server that overrides the default
  /// used by [CodePushClient]. If none is provided, [CodePushClient] will use
  /// its default.
  Uri? get hostedUri {
    try {
      final baseUrl =
          platform.environment['PATCHWING_HOSTED_URL'] ??
          getPatchwingYaml()?.baseUrl;
      return baseUrl == null ? null : Uri.tryParse(baseUrl);
    } on Exception {
      return null;
    }
  }

  /// 默认的 artifact 存储 CDN 根。
  ///
  /// 仅在所有显式来源（CLI / env / yaml）都未提供时使用。
  static const String defaultStorageBaseUrl = 'https://cdn.patchwing.net';

  /// 当前生效的 artifact 存储 CDN 根（不含尾部 `/`）。
  ///
  /// 优先级（高到低）：
  ///  1. `--storage-url` CLI 全局参数（[cliStorageUrlOverride]）；
  ///  2. `PATCHWING_STORAGE_URL` 环境变量；
  ///  3. `patchwing.yaml` 的 `storage_base_url` 字段；
  ///  4. 内置默认 [defaultStorageBaseUrl]。
  ///
  /// 注意：这里不能读取 `FLUTTER_STORAGE_BASE_URL`。该变量常被用户设为
  /// `storage.flutter-io.cn` 等 Flutter 公共镜像，只适合 Flutter 官方 artifacts，
  /// 不适合 Patchwing 私有产物（engine/flutter-cache/patch tool）。
  ///
  /// 该 getter 不会抛异常——任何一级解析失败都会回落到下一级。
  Uri get storageBaseUri {
    String? raw;
    final cli = cliStorageUrlOverride;
    if (cli != null && cli.isNotEmpty) {
      raw = cli;
    } else {
      final envUrl = platform.environment['PATCHWING_STORAGE_URL'];
      if (envUrl != null && envUrl.isNotEmpty) {
        raw = envUrl;
      } else {
        try {
          final yamlUrl = getPatchwingYaml()?.storageBaseUrl;
          if (yamlUrl != null && yamlUrl.isNotEmpty) {
            raw = yamlUrl;
          }
        } on Exception {
          // Ignore yaml parse errors here; fall through to default.
        }
      }
    }
    raw ??= defaultStorageBaseUrl;
    // 去掉尾部 `/` 以便与 `${storageBaseUri}/path/to/artifact` 这类拼接对齐。
    while (raw!.endsWith('/')) {
      raw = raw.substring(0, raw.length - 1);
    }
    return Uri.parse(raw);
  }

  /// String form of [storageBaseUri], without trailing slash.
  String get storageBaseUrl => storageBaseUri.toString();

  /// Whether the CLI can accept user input via stdin.
  ///
  /// Returns `false` when stdin/stdout is not a terminal, when running on CI,
  /// or when the user has opted into non-interactive output via `--json`.
  ///
  /// 同时检查 stdout 是否是 TTY，是为了与 mason_logger.prompt() 内部行为对齐：
  /// 当 stdout 被管道/tee 接管时，prompt() 会因为无法控制 echo 而抛
  /// "Interactive input was required ..." 错误。提前返回 false 让上层走
  /// non-interactive 默认值分支，避免崩溃。
  bool get canAcceptUserInput =>
      stdin.hasTerminal && stdout.hasTerminal && !isRunningOnCI && !isJsonMode;

  /// Whether platform.environment indicates that we are running on a CI
  /// platform. This implementation is intended to behave similar to the Flutter
  /// tool's:
  /// https://github.com/flutter/flutter/blob/0c10e1ca54ae74043909059e2ff56bf5dd0c3d23/packages/flutter_tools/lib/src/base/bot_detector.dart#L48-L69
  bool get isRunningOnCI =>
      platform.environment['BOT'] == 'true'
      // https://docs.travis-ci.com/user/environment-variables/#Default-Environment-Variables
      ||
      platform.environment['TRAVIS'] == 'true' ||
      platform.environment['CONTINUOUS_INTEGRATION'] == 'true' ||
      platform.environment.containsKey('CI') // Travis and AppVeyor
      // https://www.appveyor.com/docs/environment-variables/
      ||
      platform.environment.containsKey('APPVEYOR')
      // https://cirrus-ci.org/guide/writing-tasks/#environment-variables
      ||
      platform.environment.containsKey('CIRRUS_CI')
      // https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-env-vars.html
      ||
      (platform.environment.containsKey('AWS_REGION') &&
          platform.environment.containsKey('CODEBUILD_INITIATOR'))
      // https://wiki.jenkins.io/display/JENKINS/Building+a+software+project#Buildingasoftwareproject-belowJenkinsSetEnvironmentVariables
      ||
      platform.environment.containsKey('JENKINS_URL')
      // https://help.github.com/en/actions/configuring-and-managing-workflows/using-environment-variables#default-environment-variables
      ||
      platform.environment.containsKey('GITHUB_ACTIONS')
      // https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables?view=azure-devops&tabs=yaml
      ||
      platform.environment.containsKey('TF_BUILD');
}
