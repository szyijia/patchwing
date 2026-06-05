import 'dart:convert';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/executables/executables.dart';
import 'package:patchwing_cli/src/extensions/version.dart';
import 'package:patchwing_cli/src/flutter_version_constraints.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';
import 'package:patchwing_code_push_protocol/patchwing_code_push_protocol.dart';

/// A reference to a [PatchwingFlutter] instance.
final patchwingFlutterRef = create(PatchwingFlutter.new);

/// The [PatchwingFlutter] instance available in the current zone.
PatchwingFlutter get patchwingFlutter => read(patchwingFlutterRef);

/// {@template patchwing_flutter}
/// Helps manage the Flutter installation used by Patchwing.
/// {@endtemplate}
class PatchwingFlutter {
  /// {@macro patchwing_flutter}
  const PatchwingFlutter();

  /// The executable name.
  static const executable = 'flutter';

  /// The Patchwing Flutter fork git URL.
  static const String flutterGitUrl = 'https://github.com/szyijia/flutter.git';

  String _workingDirectory({String? revision}) {
    revision ??= patchwingEnv.flutterRevision;
    return p.join(patchwingEnv.flutterDirectory.parent.path, revision);
  }

  /// Install the provided Flutter [revision].
  ///
  /// Runs `flutter precache` on first install as a convenience so the first
  /// build is not unexpectedly slow. A precache failure is treated as a
  /// corrupted install: Flutter's stamp-based cache will otherwise trust a
  /// partial extraction and surface the missing artifact later as an opaque
  /// Gradle error (see patchwingtech/patchwing#3783). The user is directed
  /// to run `patchwing cache clean` to start over.
  Future<void> installRevision({required String revision}) async {
    final targetDirectory = Directory(_workingDirectory(revision: revision));
    if (targetDirectory.existsSync()) {
      // In mock/dev mode, if the directory already exists with all resources
      // pre-populated, skip the git clone and flutter precache steps.
      logger.detail(
        'Flutter revision $revision already installed at ${targetDirectory.path}, skipping precache.',
      );
      return;
    }

    final version = await getVersionForRevision(flutterRevision: revision);

    final installProgress = logger.progress(
      'Installing Flutter $version (${shortRevisionString(revision)})',
    );

    try {
      // Clone the Patchwing Flutter repo into the target directory.
      await git.clone(
        url: flutterGitUrl,
        outputDirectory: targetDirectory.path,
        args: ['--filter=tree:0', '--no-checkout'],
      );

      // Checkout the correct revision.
      await git.checkout(directory: targetDirectory.path, revision: revision);
      installProgress.complete();
    } catch (error) {
      final short = shortRevisionString(revision);
      installProgress.fail('Failed to install Flutter $version ($short)');
      logger.err('$error');
      rethrow;
    }

    final precacheProgress = logger.progress(
      'Downloading Dart SDK',
    );

    // Patchwing 使用 local engine，不需要从 CDN 下载 engine artifacts。
    // 直接运行 update_dart_sdk.sh 只下载 Dart SDK，避免 Flutter tool 启动时
    // 尝试下载我们魔改 engine revision 对应的 artifacts（CDN 上不存在）。
    final updateDartSdkScript = platform.isWindows
        ? p.join(targetDirectory.path, 'bin', 'internal', 'update_dart_sdk.ps1')
        : p.join(targetDirectory.path, 'bin', 'internal', 'update_dart_sdk.sh');

    // 确保 bin/cache 目录存在
    final cacheDir = Directory(p.join(targetDirectory.path, 'bin', 'cache'));
    if (!cacheDir.existsSync()) {
      cacheDir.createSync(recursive: true);
    }

    // 先运行 update_engine_version.sh 生成 engine.stamp（update_dart_sdk.sh 的 fallback 需要）
    final updateEngineScript = platform.isWindows
        ? p.join(
            targetDirectory.path,
            'bin',
            'internal',
            'update_engine_version.ps1',
          )
        : p.join(
            targetDirectory.path,
            'bin',
            'internal',
            'update_engine_version.sh',
          );

    await process.run(
      platform.isWindows ? 'powershell' : 'bash',
      [updateEngineScript],
      workingDirectory: targetDirectory.path,
      useVendedFlutter: false,
    );

    final PatchwingProcessResult result;
    try {
      result = await process.run(
        platform.isWindows ? 'powershell' : 'bash',
        [updateDartSdkScript],
        workingDirectory: targetDirectory.path,
        useVendedFlutter: false,
      );
    } on Exception catch (error) {
      precacheProgress.fail('Failed to download Dart SDK');
      throw CacheCorruptedException(
        'Failed to download Dart SDK: $error.',
      );
    }
    if (result.exitCode != ExitCode.success.code) {
      precacheProgress.fail('Failed to download Dart SDK');
      final stderr = '${result.stderr}'.trim();
      throw CacheCorruptedException(
        'update_dart_sdk exited with code ${result.exitCode}: $stderr.',
      );
    }
    precacheProgress.complete();
  }

  /// Whether the current revision is unmodified.
  Future<bool> isUnmodified({String? revision}) async {
    final status = await git.status(
      directory: _workingDirectory(revision: revision),
      args: ['--untracked-files=no', '--porcelain'],
    );
    return status.isEmpty;
  }

  /// Returns the current system Flutter version.
  /// Throws a [ProcessException] if the version check fails.
  /// Returns `null` if the version check succeeds but the version cannot be
  /// parsed.
  Future<String?> getSystemVersion() async {
    const args = ['--version'];
    final result = await process.run(executable, args, useVendedFlutter: false);

    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        args,
        '${result.stderr}',
        result.exitCode,
      );
    }

    final output = result.stdout.toString();
    final flutterVersionRegex = RegExp(r'Flutter (\d+.\d+.\d+)');
    final match = flutterVersionRegex.firstMatch(output);

    return match?.group(1);
  }

  /// Executes `flutter config --list` and returns the output as a map.
  Map<String, dynamic> getConfig() {
    final args = ['config', '--list'];
    final result = process.runSync(executable, args);
    // Gracefully handle errors (e.g. older Flutter versions that don't support
    // `flutter config --list`).
    if (result.exitCode != ExitCode.success.code) return <String, dynamic>{};
    final output = '${result.stdout}';
    final config = <String, dynamic>{};
    final lines = LineSplitter.split(output).toList();
    for (final line in lines.skip(1)) {
      final index = line.indexOf(':');
      if (index == -1) continue;
      final key = line.substring(0, index).trim();
      final value = line.substring(index + 1).trim();
      config[key] = value;
    }
    return config;
  }

  /// Converts a full git revision to a short revision string.
  String shortRevisionString(String revision) {
    if (revision.length <= 10) return revision;
    return revision.substring(0, 10);
  }

  /// Given a revision and a version, formats them into a single string.
  ///
  /// e.g. 3.16.3 and b9b2390296b9b2390296 -> 3.16.3 (b9b2390296)
  String formatVersion({required String revision, required String? version}) {
    version ??= 'unknown';
    return '$version (${shortRevisionString(revision)})';
  }

  /// Returns the current Patchwing Flutter version and revision.
  /// Returns unknown if the version check fails.
  Future<String> getVersionAndRevision() async {
    late final String? version;

    try {
      version = await getVersionString();
    } on Exception {
      version = 'unknown';
    }

    return formatVersion(
      version: version,
      revision: patchwingEnv.flutterRevision,
    );
  }

  /// Returns the current Patchwing Flutter version.
  /// Throws a [ProcessException] if the version check fails.
  /// Returns `null` if the version check succeeds but the version cannot be
  /// parsed.
  Future<String?> getVersionString() async {
    final flutterRevision = patchwingEnv.flutterRevision;
    return getVersionForRevision(flutterRevision: flutterRevision);
  }

  /// The current Patchwing Flutter version as a [Version]. Returns null if the
  /// version cannot be parsed.
  Future<Version?> getVersion() async {
    final versionString = await getVersionString();
    if (versionString == null) {
      return null;
    }

    final Version version;
    try {
      version = Version.parse(versionString);
    } on FormatException {
      return null;
    }

    return version;
  }

  /// Returns the human readable version for a given git revision
  /// e.g. b9b2390296b9b2390296 -> 3.16.3
  /// TODO: 当本地 vendor/flutter 没有对应 commit 或 flutter_release 分支时，
  /// 优雅返回 null，不阻断 patch 流程。
  Future<String?> getVersionForRevision({
    required String flutterRevision,
  }) async {
    try {
      final result = await git.forEachRef(
        contains: flutterRevision,
        format: '%(refname:short)',
        pattern: 'refs/remotes/origin/flutter_release/*',
        directory: _workingDirectory(),
      );

      return LineSplitter.split(result)
          .map((e) => e.replaceFirst('origin/flutter_release/', ''))
          .toList()
          .firstOrNull;
    } on ProcessException {
      // 本地 Flutter 仓库可能没有该 commit 或没有 flutter_release 分支，
      // 返回 null 让调用方显示 "unknown" 即可。
      return null;
    }
  }

  /// Pattern for a valid git hash (4-40 hex characters).
  /// Git allows short hashes as long as they're unambiguous.
  static final _gitHashPattern = RegExp(r'^[0-9a-fA-F]{4,40}$');

  /// Translates [versionOrHash] into a Flutter revision. If this is a semver
  /// version, it will look up the git revision for that version. If not, it
  /// will check if it's a valid git hash that exists in the local Flutter repo.
  ///
  /// Returns the full hash if valid, or null if it's neither a valid semver
  /// version nor a valid git hash that exists locally.
  Future<String?> resolveFlutterRevision(String versionOrHash) async {
    final parsedVersion = tryParseVersion(versionOrHash);
    if (parsedVersion != null) {
      return getRevisionForVersion(versionOrHash);
    }

    // If we were unable to parse the version, check if it's a valid git hash.
    if (!_gitHashPattern.hasMatch(versionOrHash)) {
      return null;
    }

    // Verify the hash exists locally by resolving it to its full hash.
    try {
      final fullHash = await git.revParse(
        revision: versionOrHash,
        directory: _workingDirectory(),
      );
      return fullHash;
    } on ProcessException {
      return null;
    }
  }

  /// Translates [versionOrHash] into a Flutter [Version]. If [versionOrHash]
  /// is semver version string, it will simply parse that into a [Version]. If
  /// not, it will assume that the input is a git commit hash and attempt to
  /// map it to a Flutter version.
  Future<Version?> resolveFlutterVersion(String versionOrHash) async {
    final parsedVersion = tryParseVersion(versionOrHash);
    if (parsedVersion != null) {
      return parsedVersion;
    }

    try {
      // If we were unable to parse the version, assume it's a revision hash.
      final versionString = await getVersionForRevision(
        flutterRevision: versionOrHash,
      );
      return versionString != null ? tryParseVersion(versionString) : null;
    } on Exception {
      return null;
    }
  }

  /// Whether `gen_snapshot` should be invoked with `--strip` for a build
  /// targeting [platform] on the Flutter pin identified by [flutterRevision].
  ///
  /// On non-Android platforms (iOS, macOS, Linux, Windows, iOS framework,
  /// AAR), AGP is not in the pipeline, so we always pre-strip in gen_snapshot.
  ///
  /// On Android, the answer depends on the Flutter version: from 3.44 onward
  /// AGP performs the strip and emits the matching `.sym` companion;
  /// pre-stripping in gen_snapshot on those versions leaves AGP with nothing
  /// to strip and trips flutter_tools' post-build verification. See
  /// [libappStrippedByAgpConstraint].
  ///
  /// An unresolvable [flutterRevision] (e.g. a development branch) is treated
  /// as satisfying the constraint, since the alternative — pre-stripping —
  /// would fail the post-build check on any 3.44+ pin.
  Future<bool> shouldPreStripLibappInGenSnapshot({
    required ReleasePlatform platform,
    required String flutterRevision,
  }) async {
    if (platform != ReleasePlatform.android) return true;
    final version = await resolveFlutterVersion(flutterRevision);
    return !libappStrippedByAgpConstraint.isSatisfiedBy(
      version: version ?? libappStrippedByAgpConstraint.minVersion,
      revision: flutterRevision,
    );
  }

  /// Fetches the latest remote refs for the Flutter clone so that
  /// release branch pointers (e.g. `flutter_release/3.38.5`) are up to date.
  Future<void> fetchRemoteRefs() async {
    try {
      await git.fetch(directory: _workingDirectory());
    } on Exception {
      logger.warn(
        'Failed to fetch latest Flutter versions. '
        'Resolving with potentially stale data.',
      );
    }
  }

  /// Returns the git revision for the provided [version].
  /// e.g. 3.16.3 -> b9b23902966504a9778f4c07e3a3487fa84dcb2a
  Future<String?> getRevisionForVersion(String version) async {
    try {
      final result = await git.revParse(
        revision: 'refs/remotes/origin/flutter_release/$version',
        directory: _workingDirectory(),
      );
      return LineSplitter.split(result).toList().firstOrNull;
    } on ProcessException {
      return null;
    }
  }

  /// Get the list of Flutter versions for the given [revision].
  Future<List<String>> getVersions({String? revision}) async {
    final result = await git.forEachRef(
      format: '%(refname:short)',
      pattern: 'refs/remotes/origin/flutter_release/*',
      directory: _workingDirectory(revision: revision),
    );
    return LineSplitter.split(
      result,
    ).map((e) => e.replaceFirst('origin/flutter_release/', '')).toList();
  }
}
