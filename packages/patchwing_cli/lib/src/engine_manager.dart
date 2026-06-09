import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/cache.dart';
import 'package:patchwing_cli/src/engine_config.dart';
import 'package:patchwing_cli/src/http_client/http_client.dart';
import 'package:patchwing_cli/src/logging/logging.dart';
import 'package:patchwing_cli/src/platform.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';

/// A reference to an [EngineManager] instance.
final engineManagerRef = create(EngineManager.new);

/// The [EngineManager] instance available in the current zone.
EngineManager get engineManager => read(engineManagerRef);

/// {@template engine_manager}
/// 管理 Patchwing 预编译 engine artifact 的下载和缓存。
///
/// 新电脑首次运行 `pw release` 时，会自动从 CDN 下载对应版本的 engine artifact，
/// 包含 flutter.jar（含 libflutter.so）和 gen_snapshot。
/// {@endtemplate}
class EngineManager {
  /// {@macro engine_manager}
  const EngineManager();

  /// CDN 上 engine artifact 的路径前缀（默认 `<storageBaseUrl>/patchwing/engine`）。
  ///
  /// 走 [PatchwingEnv.storageBaseUri]，可被 `--storage-url` / `PATCHWING_STORAGE_URL`
  /// / `patchwing.yaml` 覆写。
  String get cdnBaseUrl => '${patchwingEnv.storageBaseUrl}/patchwing/engine';

  /// 解析 engine 版本号。
  ///
  /// 优先级：
  ///  1. 显式传入的参数（一般用于测试）；
  ///  2. `<patchwingRoot>/bin/internal/engine.version` 中的 git hash；
  ///
  /// 注意：从 W8 起，engine artifact 在 CDN/缓存中均按 git hash 索引，
  /// 不再使用 `3.44.0` 这种语义版本号——hash 与二进制内容一一对应，
  /// 避免 "版本号不变但内容变" 导致的 stale 问题。
  String resolveEngineVersion([String? override]) {
    if (override != null && override.isNotEmpty) return override;
    return patchwingEnv.patchwingEngineRevision;
  }

  /// Engine artifact 的本地缓存根目录
  Directory get engineCacheDir {
    return Directory(
      p.join(Cache.patchwingCacheDirectory.path, 'engine'),
    );
  }

  /// 获取指定版本的 engine artifact 目录
  Directory getEngineDir(String engineRevision) {
    return Directory(p.join(engineCacheDir.path, engineRevision));
  }

  /// 检查 engine artifact 是否已存在且有效
  bool isEngineAvailable([String? engineRevision]) {
    final version = resolveEngineVersion(engineRevision);
    final dir = getEngineDir(version);
    final flutterJar = File(
      p.join(dir.path, 'android_release_arm64', 'flutter.jar'),
    );
    final genSnapshot = File(
      p.join(dir.path, 'host_release', 'gen_snapshot'),
    );
    return flutterJar.existsSync() && genSnapshot.existsSync();
  }

  /// 确保 engine artifact 存在。如果不存在则从 CDN 下载。
  /// 返回 engine src 路径（用于 --local-engine-src-path）。
  ///
  /// 目录结构：
  /// ```
  /// ~/.patchwing/bin/cache/engine/<engineRevision>/
  ///   ├── android_release_arm64/
  ///   │   └── flutter.jar (含 libflutter.so)
  ///   └── host_release/
  ///       └── gen_snapshot
  /// ```
  ///
  /// 开发环境：可通过 `PATCHWING_DEV_LOCAL_ENGINE_SRC` 环境变量显式指向本机
  /// engine 源码根（如 `vendor/flutter/engine/src/`），跳过 CDN 下载。
  /// 注意：不再有任何隐式 vendor fallback。
  Future<Directory?> ensureEngine([String? engineRevision]) async {
    final version = resolveEngineVersion(engineRevision);

    // 开发环境逆身通道：显式指向本机 engine src
    final devEngineSrc = platform.environment['PATCHWING_DEV_LOCAL_ENGINE_SRC'];
    if (devEngineSrc != null && devEngineSrc.isNotEmpty) {
      final dir = Directory(devEngineSrc);
      if (dir.existsSync()) {
        logger.detail(
          '[engine_manager] 使用 PATCHWING_DEV_LOCAL_ENGINE_SRC: ${dir.path}',
        );
        return dir;
      }
      logger.detail(
        '[engine_manager] PATCHWING_DEV_LOCAL_ENGINE_SRC 指向不存在的路径，忽略: ${dir.path}',
      );
    }

    if (isEngineAvailable(version)) {
      logger.detail('[engine_manager] Engine $version 已存在，跳过下载');
      return getEngineDir(version);
    }

    // 从 CDN 下载
    return _downloadEngine(version);
  }

  /// 构建 EngineConfig，供 command_runner 使用
  Future<EngineConfig?> resolveEngineConfig([String? engineRevision]) async {
    final version = resolveEngineVersion(engineRevision);
    final engineDir = await ensureEngine(version);
    if (engineDir == null) return null;
    await _ensureLocalEngineSdkLinks(engineDir: engineDir);
    await _ensureAndroidLocalEngineMavenArtifacts(
      engineDir: engineDir,
      engineRevision: version,
    );

    // 检查是否是本机 engine src（有完整的 out/ 目录结构，
    // 通常是 PATCHWING_DEV_LOCAL_ENGINE_SRC 指向的开发路径）
    final outDir = Directory(p.join(engineDir.path, 'out'));
    if (outDir.existsSync()) {
      // dev engine: engineDir = .../engine/src/
      return EngineConfig(
        localEngineSrcPath: engineDir.path,
        localEngine: 'android_release_arm64',
        localEngineHost: 'host_release',
      );
    }

    // CDN 下载的 engine: engineDir = .../cache/engine/<engineRevision>/
    // 需要构造一个兼容 flutter build 的路径结构
    // flutter build 期望: --local-engine-src-path 下有 out/<engine_name>/
    final syntheticSrcDir = Directory(p.join(engineDir.path, 'src'));
    final syntheticOutDir = Directory(p.join(syntheticSrcDir.path, 'out'));
    final androidReleaseLink = Directory(
      p.join(syntheticOutDir.path, 'android_release_arm64'),
    );
    final hostReleaseLink = Directory(
      p.join(syntheticOutDir.path, 'host_release'),
    );

    // 创建符号链接结构
    if (!syntheticOutDir.existsSync()) {
      syntheticOutDir.createSync(recursive: true);
    }
    final actualAndroidDir = Directory(
      p.join(engineDir.path, 'android_release_arm64'),
    );
    final actualHostDir = Directory(
      p.join(engineDir.path, 'host_release'),
    );

    if (!androidReleaseLink.existsSync() && actualAndroidDir.existsSync()) {
      Link(androidReleaseLink.path).createSync(actualAndroidDir.path);
    }
    if (!hostReleaseLink.existsSync() && actualHostDir.existsSync()) {
      Link(hostReleaseLink.path).createSync(actualHostDir.path);
    }

    return EngineConfig(
      localEngineSrcPath: syntheticSrcDir.path,
      localEngine: 'android_release_arm64',
      localEngineHost: 'host_release',
    );
  }

  Future<void> _ensureLocalEngineSdkLinks({
    required Directory engineDir,
  }) async {
    final androidDir = Directory(
      p.join(engineDir.path, 'android_release_arm64'),
    );
    final hostDir = Directory(p.join(engineDir.path, 'host_release'));
    if (!androidDir.existsSync() || !hostDir.existsSync()) return;

    await _ensureLink(
      linkPath: p.join(hostDir.path, 'dart-sdk'),
      targetPath: p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
      ),
    );
    await _ensureLink(
      linkPath: p.join(hostDir.path, 'gen_snapshot'),
      targetPath: p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'utils',
        'gen_snapshot',
      ),
      replaceExisting: true,
    );
    await _ensureLink(
      linkPath: p.join(androidDir.path, 'gen_snapshot'),
      targetPath: p.join(hostDir.path, 'gen_snapshot'),
      replaceExisting: true,
    );
    await _ensureLink(
      linkPath: p.join(androidDir.path, 'flutter_patched_sdk'),
      targetPath: p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
      ),
      replaceExisting: true,
    );
    await _ensureLink(
      linkPath: p.join(androidDir.path, 'flutter_patched_sdk_product'),
      targetPath: p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'common',
        'flutter_patched_sdk_product',
      ),
      replaceExisting: true,
    );
  }

  Future<void> _ensureLink({
    required String linkPath,
    required String targetPath,
    bool replaceExisting = false,
  }) async {
    if (!FileSystemEntity.isDirectorySync(targetPath) &&
        !FileSystemEntity.isFileSync(targetPath)) {
      logger.detail('[engine_manager] link target missing: $targetPath');
      return;
    }

    final link = Link(linkPath);
    if (link.existsSync()) {
      if (link.targetSync() == targetPath) return;
      await link.delete();
    } else {
      final type = FileSystemEntity.typeSync(linkPath, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        if (!replaceExisting) return;
        if (type == FileSystemEntityType.directory) {
          await Directory(linkPath).delete(recursive: true);
        } else {
          await File(linkPath).delete();
        }
      }
    }
    await link.create(targetPath, recursive: true);
  }

  Future<void> _ensureAndroidLocalEngineMavenArtifacts({
    required Directory engineDir,
    required String engineRevision,
  }) async {
    final androidDir = Directory(
      p.join(engineDir.path, 'android_release_arm64'),
    );
    final flutterJar = File(p.join(androidDir.path, 'flutter.jar'));
    if (!flutterJar.existsSync()) return;

    final requiredFiles = [
      'flutter_embedding_release.jar',
      'flutter_embedding_release.pom',
      'flutter_embedding_release.maven-metadata.xml',
      'arm64_v8a_release.jar',
      'arm64_v8a_release.pom',
      'arm64_v8a_release.maven-metadata.xml',
    ];
    final filesExist = requiredFiles.every(
      (name) => File(p.join(androidDir.path, name)).existsSync(),
    );
    final embeddingPom = File(
      p.join(androidDir.path, 'flutter_embedding_release.pom'),
    );
    final embeddingPomHasDependencies =
        embeddingPom.existsSync() &&
        embeddingPom.readAsStringSync().contains('lifecycle-common');
    if (filesExist && embeddingPomHasDependencies) return;

    logger.detail(
      '[engine_manager] synthesizing Android local-engine Maven artifacts',
    );
    final version = '1.0.0-$engineRevision';
    final tempDir = await Directory.systemTemp.createTemp('pw_engine_maven_');
    try {
      final extractResult = await Process.run('jar', [
        'xf',
        flutterJar.path,
      ], workingDirectory: tempDir.path);
      if (extractResult.exitCode != 0) {
        logger.detail(
          '[engine_manager] jar xf failed: ${extractResult.stderr}',
        );
        return;
      }

      final embeddingDir = Directory(p.join(tempDir.path, 'embedding'));
      final arm64Dir = Directory(p.join(tempDir.path, 'arm64'));
      embeddingDir.createSync(recursive: true);
      Directory(
        p.join(arm64Dir.path, 'lib', 'arm64-v8a'),
      ).createSync(recursive: true);

      final ioDir = Directory(p.join(tempDir.path, 'io'));
      if (ioDir.existsSync()) {
        await ioDir.rename(p.join(embeddingDir.path, 'io'));
      }
      final androidxDir = Directory(p.join(tempDir.path, 'androidx'));
      if (androidxDir.existsSync()) {
        await androidxDir.rename(p.join(embeddingDir.path, 'androidx'));
      }
      final metaInfDir = Directory(p.join(tempDir.path, 'META-INF'));
      if (metaInfDir.existsSync()) {
        await metaInfDir.rename(p.join(embeddingDir.path, 'META-INF'));
      }

      final libFlutter = File(
        p.join(tempDir.path, 'lib', 'arm64-v8a', 'libflutter.so'),
      );
      if (!libFlutter.existsSync()) {
        logger.detail(
          '[engine_manager] flutter.jar does not contain arm64-v8a/libflutter.so',
        );
        return;
      }
      await libFlutter.rename(
        p.join(arm64Dir.path, 'lib', 'arm64-v8a', 'libflutter.so'),
      );

      await _createJar(
        workingDirectory: embeddingDir,
        outputPath: p.join(androidDir.path, 'flutter_embedding_release.jar'),
      );
      await _createJar(
        workingDirectory: arm64Dir,
        outputPath: p.join(androidDir.path, 'arm64_v8a_release.jar'),
      );

      _writePom(
        androidDir: androidDir,
        artifactId: 'flutter_embedding_release',
        version: version,
      );
      _writePom(
        androidDir: androidDir,
        artifactId: 'arm64_v8a_release',
        version: version,
      );
      _writeMavenMetadata(
        androidDir: androidDir,
        artifactId: 'flutter_embedding_release',
        version: version,
      );
      _writeMavenMetadata(
        androidDir: androidDir,
        artifactId: 'arm64_v8a_release',
        version: version,
      );
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } on FileSystemException {
        // ignore cleanup failures
      }
    }
  }

  Future<void> _createJar({
    required Directory workingDirectory,
    required String outputPath,
  }) async {
    final result = await Process.run('jar', [
      'cf',
      outputPath,
      '.',
    ], workingDirectory: workingDirectory.path);
    if (result.exitCode != 0) {
      throw ProcessException(
        'jar',
        ['cf', outputPath, '.'],
        '${result.stderr}',
        result.exitCode,
      );
    }
  }

  void _writePom({
    required Directory androidDir,
    required String artifactId,
    required String version,
  }) {
    final dependencies = artifactId == 'flutter_embedding_release'
        ? '''
  <dependencies>
    <dependency>
      <groupId>androidx.lifecycle</groupId>
      <artifactId>lifecycle-common</artifactId>
      <version>2.7.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.lifecycle</groupId>
      <artifactId>lifecycle-common-java8</artifactId>
      <version>2.7.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.lifecycle</groupId>
      <artifactId>lifecycle-process</artifactId>
      <version>2.7.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.lifecycle</groupId>
      <artifactId>lifecycle-runtime</artifactId>
      <version>2.7.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.fragment</groupId>
      <artifactId>fragment</artifactId>
      <version>1.7.1</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.annotation</groupId>
      <artifactId>annotation</artifactId>
      <version>1.8.1</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.tracing</groupId>
      <artifactId>tracing</artifactId>
      <version>1.2.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.core</groupId>
      <artifactId>core</artifactId>
      <version>1.13.1</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.window</groupId>
      <artifactId>window-java</artifactId>
      <version>1.2.0</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>com.getkeepsafe.relinker</groupId>
      <artifactId>relinker</artifactId>
      <version>1.4.5</version>
      <scope>compile</scope>
    </dependency>
    <dependency>
      <groupId>androidx.exifinterface</groupId>
      <artifactId>exifinterface</artifactId>
      <version>1.4.1</version>
      <scope>compile</scope>
    </dependency>
  </dependencies>
'''
        : '';
    File(p.join(androidDir.path, '$artifactId.pom')).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<project>
  <modelVersion>4.0.0</modelVersion>
  <groupId>io.flutter</groupId>
  <artifactId>$artifactId</artifactId>
  <version>$version</version>
  <packaging>jar</packaging>$dependencies</project>
''');
  }

  void _writeMavenMetadata({
    required Directory androidDir,
    required String artifactId,
    required String version,
  }) {
    File(
      p.join(androidDir.path, '$artifactId.maven-metadata.xml'),
    ).writeAsStringSync('''
<?xml version="1.0" encoding="UTF-8"?>
<metadata>
  <groupId>io.flutter</groupId>
  <artifactId>$artifactId</artifactId>
  <versioning>
    <release>$version</release>
    <versions>
      <version>$version</version>
    </versions>
  </versioning>
</metadata>
''');
  }

  /// 从 CDN 下载 engine artifact
  Future<Directory?> _downloadEngine(String version) async {
    final platformName = _getPlatformName();
    final artifactName = 'patchwing-engine-$version-$platformName';
    final url = '${cdnBaseUrl}/$version/$artifactName.zip';

    final downloadProgress = logger.progress(
      '下载 Engine artifact ($version)...',
    );

    try {
      final request = http.Request('GET', Uri.parse(url));
      final response = await httpClient.send(request);

      if (response.statusCode != HttpStatus.ok) {
        downloadProgress.fail(
          'Engine artifact 下载失败: ${response.statusCode}\n'
          'URL: $url\n'
          '请确认 CDN 上已上传对应版本的 engine artifact。\n'
          '上传方法: bash scripts/package_engine.sh --upload',
        );
        return null;
      }

      // 下载到临时文件
      final tempDir = await Directory.systemTemp.createTemp('pw_engine_');
      final zipFile = File(p.join(tempDir.path, '$artifactName.zip'));
      final sink = zipFile.openWrite();
      await response.stream.pipe(sink);
      await sink.close();

      downloadProgress.complete('Engine artifact 下载完成');

      // 解压
      final extractProgress = logger.progress('解压 Engine artifact...');
      final engineDir = getEngineDir(version);
      if (!engineDir.existsSync()) {
        engineDir.createSync(recursive: true);
      }

      final result = await Process.run('unzip', [
        '-o',
        zipFile.path,
        '-d',
        engineDir.path,
      ]);

      if (result.exitCode != 0) {
        extractProgress.fail('解压失败: ${result.stderr}');
        return null;
      }

      // 设置 gen_snapshot 可执行权限
      final genSnapshot = File(
        p.join(engineDir.path, 'host_release', 'gen_snapshot'),
      );
      if (genSnapshot.existsSync() && !platform.isWindows) {
        await Process.run('chmod', ['+x', genSnapshot.path]);
      }

      // 清理临时文件
      await tempDir.delete(recursive: true);

      extractProgress.complete('Engine artifact 解压完成');
      return engineDir;
    } on Exception catch (e) {
      downloadProgress.fail('Engine artifact 下载失败: $e');
      return null;
    }
  }

  /// 获取当前平台标识
  String _getPlatformName() {
    if (platform.isMacOS) {
      // 检测 ARM64 vs x64
      final result = Process.runSync('uname', ['-m']);
      final arch = result.stdout.toString().trim();
      return arch == 'arm64' ? 'darwin-arm64' : 'darwin-x64';
    } else if (platform.isLinux) {
      return 'linux-x64';
    } else if (platform.isWindows) {
      return 'windows-x64';
    }
    return 'darwin-arm64';
  }
}
