import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/formatters/file_size_formatter.dart';
import 'package:patchwing_cli/src/http_client/http_client.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';

/// A reference to a [FlutterCacheBootstrap] instance.
final flutterCacheBootstrapRef = create(FlutterCacheBootstrap.new);

/// The [FlutterCacheBootstrap] instance available in the current zone.
FlutterCacheBootstrap get flutterCacheBootstrap =>
    read(flutterCacheBootstrapRef);

/// {@template flutter_cache_bootstrap}
/// 在 vended flutter 启动前确保 `<flutterDirectory>/bin/cache/` 是 precache
/// 完成态：含 dart-sdk、flutter_tools.snapshot 以及 host SDK artifacts。
///
/// W8 阶段去掉了对 storage.flutter-io.cn / storage.googleapis.com 等公共
/// 镜像的依赖（魔改 engine commit 在它们那里不存在，必然 404）。取而代之，
/// 我们把 vendor/flutter/bin/cache 整体打包推到自家 CDN（见
/// scripts/upload_flutter_cache.sh），客户端首次发现 cache 残缺时直接拉
/// tarball 解压完事，**完全绕开 flutter precache 机制**。
/// {@endtemplate}
class FlutterCacheBootstrap {
  /// {@macro flutter_cache_bootstrap}
  FlutterCacheBootstrap();

  /// 同一进程内只跑一次的去重锁。
  Future<void>? _inflight;

  /// 标记本次进程内已经核对过完整性，跳过后续 IO 检查。
  bool _verified = false;

  /// 关键 stamp / 二进制清单。任何一个缺失都视为 cache 残缺。
  ///
  /// 这些是 vendor/flutter precache 完成后必然存在的文件；不齐则
  /// `flutter create` 等命令一定会试图从 storage.* 拉魔改 commit 对应的
  /// artifacts.zip 而 404。
  static const List<String> _criticalRelativePaths = [
    'dart-sdk/bin/dart',
    'flutter_tools.snapshot',
    'flutter_tools.stamp',
    'engine.stamp',
    'engine-dart-sdk.stamp',
    // host SDK / engine artifacts：仅检查 `artifacts` 目录存在不够，
    // 因为残缺态下 `artifacts/engine/` 可能为空目录但其父仍在，会被误判为
    // 完整。这里再加一个二级目录哨兵：`common` 是平台无关 engine artifacts
    // （如 flutter_patched_sdk），所有平台都必有；只要它非空，可信度足够高。
    'artifacts/engine/common',
  ];

  /// 给 `_criticalRelativePaths` 中代表"目录"的项做额外的非空校验。
  ///
  /// 例如 `artifacts/engine/common` 必须真实存在且至少有一个子项；空目录被
  /// 视为残缺。这是为了识别"上次中断的 precache 留下的空架子"这种边界情况。
  static const Set<String> _nonEmptyDirectoryChecks = {
    'artifacts/engine/common',
  };

  /// 检查 [cacheDir] 是否完整。
  bool _isCacheComplete(Directory cacheDir) {
    if (!cacheDir.existsSync()) return false;
    for (final rel in _criticalRelativePaths) {
      final path = p.join(cacheDir.path, rel);
      final entity = FileSystemEntity.typeSync(path);
      if (entity == FileSystemEntityType.notFound) {
        logger.detail(
          '[flutter-cache] missing $rel under ${cacheDir.path}',
        );
        return false;
      }
      // 对哨兵目录额外做"非空"校验，避免空目录被误判为完整。
      if (_nonEmptyDirectoryChecks.contains(rel) &&
          entity == FileSystemEntityType.directory) {
        final dir = Directory(path);
        if (dir.listSync(followLinks: false).isEmpty) {
          logger.detail(
            '[flutter-cache] sentinel directory empty: $rel under '
            '${cacheDir.path}',
          );
          return false;
        }
      }
    }
    return true;
  }

  /// 当前主机平台对应的 tarball 后缀。
  String get _platformSuffix {
    if (platform.isMacOS) {
      final arch = Process.runSync('uname', ['-m']).stdout.toString().trim();
      return arch == 'arm64' ? 'darwin-arm64' : 'darwin-x64';
    }
    if (platform.isLinux) return 'linux-x64';
    if (platform.isWindows) return 'windows-x64';
    return 'darwin-arm64';
  }

  /// 远端 tarball URL：
  ///   `<storage>/<bucket>/flutter-cache/flutter-cache-<rev>-<platform>.tar.gz`
  ///
  /// 这里固定带上 `patchwing/` 前缀，对应 MinIO bucket 名 = `patchwing`，
  /// 公网 CDN 域名 `cdn.patchwing.net` 把 bucket 名映射为 URL 的第一级路径
  /// 段。如果未来 CDN 改造（例如 host-style），这块需要同步调整。
  /// 路径结构与 [scripts/upload_flutter_cache.sh] 上传布局保持一致。
  Uri _resolveTarballUri({required String revision}) {
    final base = patchwingEnv.storageBaseUri;
    final name = 'flutter-cache-$revision-$_platformSuffix.tar.gz';
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        'patchwing',
        'flutter-cache',
        name,
      ],
    );
  }

  /// 确保 vended flutter 的 `bin/cache/` 完整。幂等、并发安全。
  ///
  /// 调用时机：所有 `process.start('flutter', ...)` / `process.run('flutter',
  /// ...)` 之前；由 [PatchwingProcess] 透明触发。
  Future<void> ensureReady() {
    if (_verified) return Future.value();
    return _inflight ??= _ensureReadyImpl().whenComplete(() {
      _inflight = null;
    });
  }

  Future<void> _ensureReadyImpl() async {
    final flutterDir = patchwingEnv.flutterDirectory;
    final cacheDir = Directory(p.join(flutterDir.path, 'bin', 'cache'));

    if (_isCacheComplete(cacheDir)) {
      _verified = true;
      return;
    }

    if (!flutterDir.existsSync()) {
      // flutter SDK 自身都没准备好，交给 PatchwingFlutter.installRevision
      // 走更完整的 git clone + bootstrap 流程，这里不越权。
      logger.detail(
        '[flutter-cache] flutter SDK 目录尚未存在，跳过 cache bootstrap：'
        '${flutterDir.path}',
      );
      return;
    }

    final revision = patchwingEnv.flutterRevision;
    final tarballUri = _resolveTarballUri(revision: revision);
    final progress = logger.progress(
      'Bootstrapping Flutter cache from ${tarballUri.host}',
    );

    final downloadsDir = Directory(
      p.join(patchwingEnv.patchwingRoot.path, 'bin', 'cache', 'downloads'),
    );
    if (!downloadsDir.existsSync()) downloadsDir.createSync(recursive: true);

    final tarballFile = File(
      p.join(downloadsDir.path, p.basename(tarballUri.path)),
    );
    final partialFile = File('${tarballFile.path}.part');

    try {
      final remoteInfo = await _fetchRemoteFileInfo(tarballUri);
      await _downloadWithProgress(
        uri: tarballUri,
        outputFile: tarballFile,
        partialFile: partialFile,
        expectedBytes: remoteInfo.contentLength,
        progress: progress,
      );
    } on _DownloadHttpException catch (e) {
      progress.fail(
        'Flutter cache tarball 下载失败: HTTP ${e.statusCode}\n'
        'URL: $tarballUri\n'
        '请确认 CDN 上已上传：bash scripts/upload_flutter_cache.sh',
      );
      return;
    } on Exception catch (e) {
      progress.fail(
        'Flutter cache tarball 下载异常: $e\n'
        'URL: $tarballUri',
      );
      return;
    }

    // 解压：tarball 内根目录是 "cache/"，期望落到 <flutterDir>/bin/ 下。
    final binDir = Directory(p.join(flutterDir.path, 'bin'));
    if (!binDir.existsSync()) binDir.createSync(recursive: true);

    // 删掉残缺 cache 后再解（避免 stamp 错乱）
    if (cacheDir.existsSync()) {
      try {
        cacheDir.deleteSync(recursive: true);
      } on FileSystemException catch (e) {
        logger.detail('[flutter-cache] 旧 cache 删除失败（继续覆盖解压）: $e');
      }
    }

    progress.update('Extracting Flutter cache');
    final tarResult = await Process.run('tar', [
      '-xzf',
      tarballFile.path,
      '-C',
      binDir.path,
    ]);

    if (tarResult.exitCode != 0) {
      progress.fail(
        'Flutter cache tarball 解压失败 (exit ${tarResult.exitCode})\n'
        'stderr: ${tarResult.stderr}',
      );
      return;
    }

    if (!_isCacheComplete(cacheDir)) {
      progress.fail(
        'Flutter cache 解压后仍不完整，请检查 tarball 内容是否正确：'
        '${cacheDir.path}',
      );
      return;
    }

    _verified = true;
    progress.complete('Flutter cache 已就绪');
  }

  Future<_RemoteFileInfo> _fetchRemoteFileInfo(Uri uri) async {
    try {
      final request = http.Request('HEAD', uri);
      final response = await httpClient.send(request);
      // 快速 drain HEAD 响应（通常无 body），但不要为了 drain 而阻塞太久。
      await response.stream.drain<void>().timeout(const Duration(seconds: 5));
      if (response.statusCode != HttpStatus.ok) {
        // 文件不存在就不要继续走下载流程了，直接抛出 404 让上层提示。
        throw _DownloadHttpException(response.statusCode);
      }
      return _RemoteFileInfo(
        contentLength: int.tryParse(response.headers['content-length'] ?? ''),
      );
    } on _DownloadHttpException {
      rethrow;
    } on Exception catch (e) {
      logger.detail('[flutter-cache] HEAD $uri failed: $e');
      throw _DownloadHttpException(-1);
    }
  }

  Future<void> _downloadWithProgress({
    required Uri uri,
    required File outputFile,
    required File partialFile,
    required int? expectedBytes,
    required Progress progress,
  }) async {
    if (outputFile.existsSync() &&
        expectedBytes != null &&
        outputFile.lengthSync() == expectedBytes) {
      progress.update(
        'Using cached Flutter cache tarball (${formatBytes(expectedBytes)})',
      );
      return;
    }

    if (outputFile.existsSync()) outputFile.deleteSync();

    var resumeBytes = partialFile.existsSync() ? partialFile.lengthSync() : 0;
    if (expectedBytes != null && resumeBytes >= expectedBytes) {
      if (resumeBytes == expectedBytes) {
        partialFile.renameSync(outputFile.path);
        progress.update(
          'Using completed Flutter cache tarball (${formatBytes(expectedBytes)})',
        );
        return;
      }
      partialFile.deleteSync();
      resumeBytes = 0;
    }

    final request = http.Request('GET', uri);
    if (resumeBytes > 0) {
      request.headers['Range'] = 'bytes=$resumeBytes-';
      progress.update(
        'Resuming Flutter cache download from ${formatBytes(resumeBytes)}',
      );
    }

    final response = await httpClient.send(request);
    var append = false;
    var totalBytes = expectedBytes;
    var downloadedBytes = resumeBytes;

    if (resumeBytes > 0 && response.statusCode == HttpStatus.partialContent) {
      append = true;
      totalBytes =
          _contentRangeTotal(response) ??
          expectedBytes ??
          resumeBytes + (response.contentLength ?? 0);
    } else if (response.statusCode == HttpStatus.ok) {
      if (resumeBytes > 0 && partialFile.existsSync()) partialFile.deleteSync();
      resumeBytes = 0;
      downloadedBytes = 0;
      totalBytes = response.contentLength ?? expectedBytes;
    } else if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      if (partialFile.existsSync()) partialFile.deleteSync();
      throw _DownloadHttpException(response.statusCode);
    } else {
      throw _DownloadHttpException(response.statusCode);
    }

    var lastPercent = -1;
    var lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
    final sink = partialFile.openWrite(
      mode: append ? FileMode.append : FileMode.write,
    );

    void updateProgress({bool force = false}) {
      final now = DateTime.now();
      final percent = totalBytes == null || totalBytes <= 0
          ? -1
          : ((downloadedBytes / totalBytes) * 100).floor();
      if (!force &&
          percent == lastPercent &&
          now.difference(lastUpdate) < const Duration(milliseconds: 500)) {
        return;
      }
      lastPercent = percent;
      lastUpdate = now;
      progress.update(_downloadProgressMessage(downloadedBytes, totalBytes));
    }

    try {
      updateProgress(force: true);
      await for (final chunk in response.stream) {
        downloadedBytes += chunk.length;
        sink.add(chunk);
        updateProgress();
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (totalBytes != null && downloadedBytes != totalBytes) {
      throw StateError(
        'downloaded ${formatBytes(downloadedBytes)} but expected '
        '${formatBytes(totalBytes)}',
      );
    }

    if (outputFile.existsSync()) outputFile.deleteSync();
    partialFile.renameSync(outputFile.path);
    updateProgress(force: true);
  }

  int? _contentRangeTotal(http.StreamedResponse response) {
    final contentRange = response.headers['content-range'];
    if (contentRange == null) return null;
    final match = RegExp(r'bytes \d+-\d+/(\d+|\*)').firstMatch(contentRange);
    final total = match?.group(1);
    if (total == null || total == '*') return null;
    return int.tryParse(total);
  }

  String _downloadProgressMessage(int downloadedBytes, int? totalBytes) {
    if (totalBytes == null || totalBytes <= 0) {
      return 'Downloading Flutter cache (${formatBytes(downloadedBytes)})';
    }

    final ratio = downloadedBytes / totalBytes;
    final percent = (ratio * 100).clamp(0, 100).toStringAsFixed(1);
    const barWidth = 20;
    final filled = (ratio * barWidth).clamp(0, barWidth).floor();
    final bar = '${'█' * filled}${'░' * (barWidth - filled)}';
    return 'Downloading Flutter cache [$bar] $percent% '
        '(${formatBytes(downloadedBytes)} / ${formatBytes(totalBytes)})';
  }
}

class _RemoteFileInfo {
  const _RemoteFileInfo({this.contentLength});

  final int? contentLength;
}

class _DownloadHttpException implements Exception {
  const _DownloadHttpException(this.statusCode);

  final int statusCode;

  @override
  String toString() => 'HTTP $statusCode';
}
