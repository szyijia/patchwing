import 'dart:ffi' show Abi;
import 'dart:io' hide Platform;

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:retry/retry.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/abi.dart';
import 'package:patchwing_cli/src/artifact_manager.dart';
import 'package:patchwing_cli/src/checksum_checker.dart';
import 'package:patchwing_cli/src/flutter_version_constraints.dart';
import 'package:patchwing_cli/src/http_client/http_client.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_artifacts.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';
import 'package:patchwing_cli/src/patchwing_flutter.dart';
import 'package:patchwing_cli/src/patchwing_process.dart';

/// {@template cache_update_failure}
/// Thrown when a cache update fails.
/// This can occur if the artifact is unreachable or
/// if the download is interrupted.
/// {@endtemplate}
class CacheUpdateFailure implements Exception {
  /// {@macro cache_update_failure}
  const CacheUpdateFailure(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => 'CacheUpdateFailure: $message';
}

/// A reference to a [Cache] instance.
final cacheRef = create(Cache.new);

/// The [Cache] instance available in the current zone.
Cache get cache => read(cacheRef);

/// {@template cache}
/// A class that manages the artifacts cached by Patchwing.
/// This class handles fetching and unpacking artifacts from various sources.
///
/// To access specific artifacts, it's generally recommended to use
/// [PatchwingArtifacts] since uses the current Patchwing environment.
/// {@endtemplate}
class Cache {
  /// {@macro cache}
  Cache() {
    registerArtifact(PatchArtifact(cache: this, platform: platform));
    registerArtifact(BundleToolArtifact(cache: this, platform: platform));
    registerArtifact(AotToolsArtifact(cache: this, platform: platform));
  }

  /// Register a new [CachedArtifact] with the cache.
  void registerArtifact(CachedArtifact artifact) => _artifacts.add(artifact);

  /// Update all artifacts in the cache.
  ///
  /// [retryDelayFactor] is the delay between retries that doubles after every
  /// attempt. The default from the retry package is 200ms. This is settable for
  /// testing.
  Future<void> updateAll([
    Duration retryDelayFactor = const Duration(milliseconds: 200),
  ]) async {
    for (final artifact in _artifacts) {
      if (await artifact.isValid()) {
        continue;
      }

      await retry(
        artifact.update,
        maxAttempts: 3,
        delayFactor: retryDelayFactor,
        onRetry: (e) {
          logger
            ..detail('Failed to update ${artifact.fileName}, retrying...')
            ..detail(e.toString());
        },
      );
    }
  }

  /// Get a named directory from with the cache's artifact directory;
  /// for example, `foo` would return `bin/cache/artifacts/foo`.
  Directory getArtifactDirectory(String name) {
    return Directory(
      p.join(patchwingArtifactsDirectory.path, p.withoutExtension(name)),
    );
  }

  /// Get a named directory from with the cache's preview directory;
  /// for example, `foo` would return `bin/cache/previews/foo`.
  Directory getPreviewDirectory(String name) {
    return Directory(
      p.join(patchwingPreviewsDirectory.path, p.withoutExtension(name)),
    );
  }

  /// The Patchwing cache directory.
  static Directory get patchwingCacheDirectory {
    return Directory(p.join(patchwingEnv.patchwingRoot.path, 'bin', 'cache'));
  }

  /// The Patchwing cached previews directory.
  static Directory get patchwingPreviewsDirectory {
    return Directory(p.join(patchwingCacheDirectory.path, 'previews'));
  }

  /// The Patchwing cached artifacts directory.
  static Directory get patchwingArtifactsDirectory {
    return Directory(p.join(patchwingCacheDirectory.path, 'artifacts'));
  }

  final List<CachedArtifact> _artifacts = [];

  /// The storage base url.
  ///
  /// 透传 [PatchwingEnv.storageBaseUrl]，使 `--storage-url` / 环境变量 /
  /// `patchwing.yaml` 的覆盖配置对 [CachedArtifact] 子类生效。
  String get storageBaseUrl => patchwingEnv.storageBaseUrl;

  /// The storage bucket host.
  String get storageBucket => 'patchwing';

  /// Clear the cache.
  Future<void> clear() async {
    final cacheDir = patchwingCacheDirectory;
    if (cacheDir.existsSync()) {
      await cacheDir.delete(recursive: true);
    }
  }
}

/// {@template cached_artifact}
/// An artifact which is cached by Patchwing.
/// {@endtemplate}
abstract class CachedArtifact {
  /// {@macro cached_artifact}
  CachedArtifact({required this.cache, required this.platform});

  /// The cache instance to use.
  final Cache cache;

  /// The platform to use.
  final Platform platform;

  /// The on-disk name of the artifact.
  String get fileName;

  /// Should the artifact be marked executable.
  bool get isExecutable;

  /// The URL from which the artifact can be downloaded. Returned as a
  /// future so subclasses can resolve runtime context (e.g. the active
  /// Flutter version) before deciding which artifact to fetch.
  Future<String> get storageUrl;

  /// Whether the artifact is required for Patchwing to function.
  /// If we fail to fetch it we will exit with an error.
  bool get required => true;

  /// The SHA256 checksum of the artifact binary.
  ///
  /// When null, the checksum is not verified and the downloaded artifact
  /// is assumed to be correct.
  String? get checksum;

  /// Extract the artifact from the provided [stream] to the [outputPath].
  Future<void> extractArtifact(http.ByteStream stream, String outputPath) {
    final file = File(p.join(outputPath, fileName))
      ..createSync(recursive: true);
    return stream.pipe(file.openWrite());
  }

  /// The artifact file on disk.
  File get file =>
      File(p.join(cache.getArtifactDirectory(fileName).path, fileName));

  /// Used to validate that the artifact was fully downloaded and extracted.
  File get stampFile => File('${file.path}.stamp');

  /// Whether the artifact is valid (has a matching checksum).
  Future<bool> isValid() async {
    if (!file.existsSync() || !stampFile.existsSync()) {
      return false;
    }

    if (checksum == null) {
      logger.detail(
        '''No checksum provided for $fileName, skipping file corruption validation''',
      );
      return true;
    }

    return checksumChecker.checkFile(file, checksum!);
  }

  /// Re-fetch the artifact from the storage URL.
  Future<void> update() async {
    // Clear any existing artifact files.
    await _delete();

    final updateProgress = logger.progress('Downloading $fileName...');

    final url = await storageUrl;
    final request = http.Request('GET', Uri.parse(url));
    final http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (error) {
      throw CacheUpdateFailure('''
Failed to download $fileName: $error
If you're behind a firewall/proxy, please, make sure patchwing_cli is
allowed to access $url.''');
    }

    if (response.statusCode != HttpStatus.ok) {
      if (!required && response.statusCode == HttpStatus.notFound) {
        logger.detail(
          '[cache] optional artifact: "$fileName" was not found, skipping...',
        );
        return;
      }

      updateProgress.fail();
      throw CacheUpdateFailure(
        '''Failed to download $fileName: ${response.statusCode} ${response.reasonPhrase}''',
      );
    }

    updateProgress.complete();

    final extractProgress = logger.progress('Extracting $fileName...');
    final artifactDirectory = Directory(p.dirname(file.path));
    try {
      await extractArtifact(response.stream, artifactDirectory.path);
    } catch (_) {
      extractProgress.fail();
      rethrow;
    }

    final expectedChecksum = checksum;
    if (expectedChecksum != null) {
      if (!checksumChecker.checkFile(file, expectedChecksum)) {
        extractProgress.fail();
        // Delete the artifact directory, so if the download is retried, it will
        // be re-downloaded.
        artifactDirectory.deleteSync(recursive: true);
        throw CacheUpdateFailure(
          '''Failed to download $fileName: checksum mismatch''',
        );
      } else {
        logger.detail(
          '''No checksum provided for $fileName, skipping file corruption validation''',
        );
      }
    }

    if (!platform.isWindows && isExecutable) {
      final result = await process.start('chmod', ['+x', file.path]);
      await result.exitCode;
    }

    extractProgress.complete();
    _writeStampFile();
  }

  // Writes a 0-byte file to indicate that the artifact was successfully
  // installed.
  void _writeStampFile() {
    stampFile.createSync(recursive: true);
  }

  Future<void> _delete() async {
    if (file.existsSync()) {
      await file.delete();
    }

    if (stampFile.existsSync()) {
      await stampFile.delete();
    }
  }
}

/// {@template aot_tools_artifact}
/// The aot_tools.dill artifact.
/// Used for linking and generating optimized AOT snapshots.
/// {@endtemplate}
class AotToolsArtifact extends CachedArtifact {
  /// {@macro aot_tools_artifact}
  AotToolsArtifact({required super.cache, required super.platform});

  @override
  String get fileName => 'aot-tools.dill';

  @override
  bool get isExecutable => false;

  /// The aot-tools are only available for revisions that support mixed-mode.
  @override
  bool get required => false;

  @override
  File get file => File(
    p.join(
      cache.getArtifactDirectory(fileName).path,
      patchwingEnv.patchwingEngineRevision,
      fileName,
    ),
  );

  @override
  Future<String> get storageUrl async =>
      '${cache.storageBaseUrl}/${cache.storageBucket}/patchwing/${patchwingEnv.patchwingEngineRevision}/$fileName';

  @override
  String? get checksum => null;
}

/// {@template patch_artifact}
/// The patch artifact which is used to apply binary patches.
/// {@endtemplate}
class PatchArtifact extends CachedArtifact {
  /// {@macro patch_artifact}
  PatchArtifact({required super.cache, required super.platform});

  @override
  String get fileName => platform.isWindows ? 'patch.exe' : 'patch';

  @override
  bool get isExecutable => true;

  @override
  Future<void> extractArtifact(
    http.ByteStream stream,
    String outputPath,
  ) async {
    final tempDir = Directory.systemTemp.createTempSync();
    final artifactPath = p.join(tempDir.path, '$fileName.zip');
    await stream.pipe(File(artifactPath).openWrite());
    await artifactManager.extractZip(
      zipFile: File(artifactPath),
      outputDirectory: Directory(outputPath),
    );
  }

  @override
  Future<String> get storageUrl async {
    var artifactName = 'patch-';
    if (platform.isMacOS) {
      final useArm64 =
          abi.current == Abi.macosArm64 && await _supportsArm64Patch();
      artifactName += useArm64 ? 'darwin-arm64.zip' : 'darwin-x64.zip';
    } else if (platform.isLinux) {
      artifactName += 'linux-x64.zip';
    } else if (platform.isWindows) {
      artifactName += 'windows-x64.zip';
    }

    return '${cache.storageBaseUrl}/${cache.storageBucket}/patchwing/${patchwingEnv.patchwingEngineRevision}/$artifactName';
  }

  Future<bool> _supportsArm64Patch() async {
    final revision = patchwingEnv.flutterRevision;
    final version = await patchwingFlutter.resolveFlutterVersion(revision);
    return arm64PatchSupportConstraint.isSatisfiedBy(
      version: version ?? arm64PatchSupportConstraint.minVersion,
      revision: revision,
    );
  }

  @override
  String? get checksum => null;

  /// W8 固化阶段：去掉所有隐式 fallback。
  ///
  /// 优先级链（明确、唯一）：
  ///   1. 若设置了 `PATCHWING_DEV_BSDIFF_PATH`（开发逃生通道，仅供本仓库
  ///      开发者使用），直接复制该文件作为 patch 工具；
  ///   2. 否则从 CDN 下载（用户环境唯一路径）。
  ///
  /// 用户环境绝不应该设置 `PATCHWING_DEV_*` 环境变量。
  @override
  Future<void> update() async {
    final devPath = platform.environment['PATCHWING_DEV_BSDIFF_PATH'];
    if (devPath != null && devPath.isNotEmpty) {
      final devFile = File(devPath);
      if (!devFile.existsSync()) {
        throw CacheUpdateFailure(
          'PATCHWING_DEV_BSDIFF_PATH 指向的文件不存在: $devPath\n'
          '若不打算使用开发版 patch 工具，请 unset 该环境变量。',
        );
      }
      logger.detail('[cache] 使用开发版 patch 工具: $devPath');
      await _delete();
      final artifactDir = Directory(p.dirname(file.path));
      if (!artifactDir.existsSync()) {
        artifactDir.createSync(recursive: true);
      }
      await devFile.copy(file.path);
      if (!platform.isWindows) {
        await Process.run('chmod', ['+x', file.path]);
      }
      _writeStampFile();
      return;
    }

    // 用户环境唯一路径：从 CDN 下载
    final url = await storageUrl;
    logger.detail('[cache] 从 CDN 下载 patch 工具: $url');
    final request = http.Request('GET', Uri.parse(url));
    final http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (error) {
      throw CacheUpdateFailure(
        'patch 工具下载失败: $error\n'
        'URL: $url\n'
        '若网络不可达，开发者可以临时设置 PATCHWING_DEV_BSDIFF_PATH 指向本机 patch 二进制。',
      );
    }

    if (response.statusCode != HttpStatus.ok) {
      throw CacheUpdateFailure(
        'patch 工具下载失败: ${response.statusCode}\n'
        'URL: $url\n'
        '请确认 CDN 上已上传对应版本的 patch 二进制。',
      );
    }

    await _delete();
    final artifactDir = Directory(p.dirname(file.path));
    await extractArtifact(response.stream, artifactDir.path);
    if (!platform.isWindows) {
      await Process.run('chmod', ['+x', file.path]);
    }
    _writeStampFile();
  }
}

/// {@template bundle_tool_artifact}
/// The bundletool.jar artifact.
/// Used for interacting with Android app bundles (aab).
/// {@endtemplate}
class BundleToolArtifact extends CachedArtifact {
  /// {@macro bundle_tool_artifact}
  BundleToolArtifact({required super.cache, required super.platform});

  @override
  String get fileName => 'bundletool.jar';

  @override
  bool get isExecutable => false;

  @override
  Future<String> get storageUrl async {
    return 'https://github.com/google/bundletool/releases/download/1.18.1/bundletool-all-1.18.1.jar';
  }

  @override
  String? get checksum =>
      // SHA-256 checksum of the bundletool.jar file.
      // When updating the bundletool version, be sure to update this checksum.
      // This can be done by running the following command:
      // ```shell
      // shasum --algorithm 256 /path/to/file
      // ```
      '''675786493983787ffa11550bdb7c0715679a44e1643f3ff980a529e9c822595c''';
}
