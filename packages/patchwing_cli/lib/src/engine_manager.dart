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

  /// 检查 engine artifact 是否已存在且有效。
  ///
  /// 注意：这里校验的是能支撑 `flutter build --local-engine` 的完整闭包，
  /// 不能只看 `flutter.jar + host_release/gen_snapshot`。否则干净机器会在
  /// release 阶段拼出错误的 AOT 工具链，最终生成无法启动的 APK。
  bool isEngineAvailable([String? engineRevision]) {
    final version = resolveEngineVersion(engineRevision);
    final dir = getEngineDir(version);
    return _missingEngineArtifactFiles(dir).isEmpty;
  }

  /// 确保 engine artifact 存在。如果不存在则从 CDN 下载。
  /// 返回 engine src 路径（用于 --local-engine-src-path）。
  ///
  /// 目录结构：
  /// ```
  /// ~/.patchwing/bin/cache/engine/<engineRevision>/
  ///   ├── android_release_arm64/
  ///   │   ├── flutter.jar (含 libflutter.so)
  ///   │   ├── gen_snapshot
  ///   │   ├── flutter_patched_sdk/
  ///   │   └── flutter_patched_sdk_product/
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

    final existingDir = getEngineDir(version);
    final missing = _missingEngineArtifactFiles(existingDir);
    if (missing.isEmpty) {
      logger.detail('[engine_manager] Engine $version 已存在，跳过下载');
      return existingDir;
    }
    if (existingDir.existsSync()) {
      logger.detail(
        '[engine_manager] Engine $version 缓存不完整，重新下载。missing: ${missing.join(', ')}',
      );
      await existingDir.delete(recursive: true);
    }

    // 从 CDN 下载
    final downloaded = await _downloadEngine(version);
    if (downloaded != null) {
      final stillMissing = _missingEngineArtifactFiles(downloaded);
      if (stillMissing.isNotEmpty) {
        throw StateError(
          'Patchwing engine artifact 不完整，不能继续 release。\n'
          'engine=$version\n'
          'missing=${stillMissing.join(', ')}\n'
          '请重新按 docs/PATCHWING_BUILD_RELEASE_GUIDE.md 打包并上传完整 engine artifact。',
        );
      }
    }
    return downloaded;
  }

  /// `--target-platform` 值到 engine out/ 目录名的映射。
  /// 与 engine GN 构建输出一致：
  ///   android-arm   → android_release       (armeabi-v7a)
  ///   android-arm64 → android_release_arm64
  ///   android-x64   → android_release_x64
  static const abiDirByTargetPlatform = <String, String>{
    'android-arm': 'android_release',
    'android-arm64': 'android_release_arm64',
    'android-x64': 'android_release_x64',
  };

  /// 构建 EngineConfig，供 command_runner 使用。
  ///
  /// [targetAbi] 为 `--target-platform` 的第一个值（如 android-arm），
  /// 用于选择 per-ABI 的 local-engine 目录；缺省 android-arm64（历史默认）。
  Future<EngineConfig?> resolveEngineConfig([
    String? engineRevision,
    String? targetAbi,
  ]) async {
    final version = resolveEngineVersion(engineRevision);
    final abiDir = abiDirByTargetPlatform[targetAbi] ?? 'android_release_arm64';
    final engineDir = await ensureEngine(version);
    if (engineDir == null) return null;
    await _ensureLocalEngineSdkLinks(engineDir: engineDir);

    // 目标 ABI 的 engine 产物必须存在（旧 engine 包可能只有 arm64）。
    final abiAndroidDir = Directory(p.join(engineDir.path, abiDir));
    final abiFlutterJar = File(p.join(abiAndroidDir.path, 'flutter.jar'));
    final isDevEngineSrc = Directory(p.join(engineDir.path, 'out')).existsSync();
    if (!isDevEngineSrc && !abiFlutterJar.existsSync()) {
      logger.err(
        '''engine 包缺少 $abiDir/flutter.jar（--target-platform $targetAbi 需要该 ABI 的 engine 产物）。
请更新 engine 包：rm -rf ${engineDir.path} 后重试（会自动重新下载）。''',
      );
      return null;
    }

    await _ensureAndroidLocalEngineMavenArtifacts(
      engineDir: engineDir,
      engineRevision: version,
      androidDir: abiAndroidDir,
      abiJarName: _abiJarName(abiDir),
      abiLibDirName: _abiLibDirName(abiDir),
    );

    // 检查是否是本机 engine src（有完整的 out/ 目录结构，
    // 通常是 PATCHWING_DEV_LOCAL_ENGINE_SRC 指向的开发路径）
    if (isDevEngineSrc) {
      // dev engine: engineDir = .../engine/src/
      return EngineConfig(
        localEngineSrcPath: engineDir.path,
        localEngine: abiDir,
        localEngineHost: 'host_release',
      );
    }

    // CDN 下载的 engine: engineDir = .../cache/engine/<engineRevision>/
    // 需要构造一个兼容 flutter build 的路径结构
    // flutter build 期望: --local-engine-src-path 下有 out/<engine_name>/
    final syntheticSrcDir = Directory(p.join(engineDir.path, 'src'));
    final syntheticOutDir = Directory(p.join(syntheticSrcDir.path, 'out'));
    final androidReleaseLink = Directory(p.join(syntheticOutDir.path, abiDir));
    final hostReleaseLink = Directory(
      p.join(syntheticOutDir.path, 'host_release'),
    );

    // 创建符号链接结构
    if (!syntheticOutDir.existsSync()) {
      syntheticOutDir.createSync(recursive: true);
    }
    final actualHostDir = Directory(
      p.join(engineDir.path, 'host_release'),
    );

    if (!androidReleaseLink.existsSync() && abiAndroidDir.existsSync()) {
      Link(androidReleaseLink.path).createSync(abiAndroidDir.path);
    }
    if (!hostReleaseLink.existsSync() && actualHostDir.existsSync()) {
      Link(hostReleaseLink.path).createSync(actualHostDir.path);
    }

    return EngineConfig(
      localEngineSrcPath: syntheticSrcDir.path,
      localEngine: abiDir,
      localEngineHost: 'host_release',
    );
  }

  /// engine out 目录名 → ABI 专用 maven jar 名（io.flutter:<name>）。
  static String _abiJarName(String abiDir) {
    switch (abiDir) {
      case 'android_release':
        return 'armeabi_v7a_release';
      case 'android_release_x64':
        return 'x86_64_release';
      case 'android_release_arm64':
      default:
        return 'arm64_v8a_release';
    }
  }

  /// engine out 目录名 → flutter.jar 内 libflutter.so 的 ABI 子目录名。
  static String _abiLibDirName(String abiDir) {
    switch (abiDir) {
      case 'android_release':
        return 'armeabi-v7a';
      case 'android_release_x64':
        return 'x86_64';
      case 'android_release_arm64':
      default:
        return 'arm64-v8a';
    }
  }

  List<String> _missingEngineArtifactFiles(Directory engineDir) {
    final genSnapshot = _genSnapshotFileName();
    final requiredPaths = [
      p.join('android_release_arm64', 'flutter.jar'),
      p.join('android_release_arm64', genSnapshot),
      p.join('android_release_arm64', 'flutter_patched_sdk_product'),
      p.join('host_release', genSnapshot),
    ];
    final missing = <String>[];
    for (final rel in requiredPaths) {
      final path = p.join(engineDir.path, rel);
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        missing.add(rel);
        continue;
      }
      // android_release_arm64 下的 AOT 工具链必须由 engine artifact 自身携带。
      // 允许包内相对 symlink，不允许指向 ~/.patchwing 的 Flutter cache 或 Dart SDK。
      if (rel.startsWith('android_release_arm64') &&
          _isExternalLink(path, engineDir)) {
        missing.add('$rel (external symlink)');
      }
    }

    // flutter build 的 sdk-root 实际指向 android_release_arm64/flutter_patched_sdk。
    // 允许它是 flutter_patched_sdk_product 的同包内 symlink，但不允许完全缺失。
    final patchedSdk = p.join(
      engineDir.path,
      'android_release_arm64',
      'flutter_patched_sdk',
    );
    final patchedSdkProduct = p.join(
      engineDir.path,
      'android_release_arm64',
      'flutter_patched_sdk_product',
    );
    if (FileSystemEntity.typeSync(patchedSdk) ==
            FileSystemEntityType.notFound &&
        FileSystemEntity.typeSync(patchedSdkProduct) ==
            FileSystemEntityType.notFound) {
      missing.add(p.join('android_release_arm64', 'flutter_patched_sdk'));
    }
    if (FileSystemEntity.typeSync(patchedSdk) !=
            FileSystemEntityType.notFound &&
        _isExternalLink(patchedSdk, engineDir)) {
      missing.add(
        '${p.join('android_release_arm64', 'flutter_patched_sdk')} (external symlink)',
      );
    }
    if (FileSystemEntity.typeSync(patchedSdkProduct) !=
            FileSystemEntityType.notFound &&
        _isExternalLink(patchedSdkProduct, engineDir)) {
      missing.add(
        '${p.join('android_release_arm64', 'flutter_patched_sdk_product')} (external symlink)',
      );
    }
    return missing;
  }

  bool _isExternalLink(String path, Directory engineDir) {
    final link = Link(path);
    if (!link.existsSync()) return false;
    final target = link.targetSync();
    final resolved = p.isAbsolute(target)
        ? target
        : p.normalize(p.join(p.dirname(path), target));
    return !p.isWithin(engineDir.path, resolved) && resolved != engineDir.path;
  }

  String _genSnapshotFileName() =>
      platform.isWindows ? 'gen_snapshot.exe' : 'gen_snapshot';

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

    // 只允许在 engine artifact 内部补齐等价别名；不要从 vended Flutter cache
    // 或 Dart SDK 拼 AOT 工具链。缺少 target gen_snapshot / patched SDK 时必须
    // fail fast，避免生成“构建成功但启动崩溃”的 AAB。
    final missing = _missingEngineArtifactFiles(engineDir);
    if (missing.isNotEmpty) {
      throw StateError(
        'Patchwing engine artifact 不完整，不能继续 release。\n'
        'engineDir=${engineDir.path}\n'
        'missing=${missing.join(', ')}',
      );
    }

    final patchedSdk = Directory(
      p.join(androidDir.path, 'flutter_patched_sdk'),
    );
    final patchedSdkProduct = Directory(
      p.join(androidDir.path, 'flutter_patched_sdk_product'),
    );
    if (!patchedSdk.existsSync() && patchedSdkProduct.existsSync()) {
      await _ensureLink(
        linkPath: patchedSdk.path,
        targetPath: patchedSdkProduct.path,
      );
    }
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

  /// 在 [androidDir] 内合成 local-engine Maven 产物（flutter_embedding_release
  /// + per-ABI 的 libflutter.so jar）。embedding jar 是 ABI 中性的；
  /// [abiJarName]/[abiLibDirName] 区分 arm64_v8a/armeabi_v7a/x86_64。
  Future<void> _ensureAndroidLocalEngineMavenArtifacts({
    required Directory engineDir,
    required String engineRevision,
    required Directory androidDir,
    required String abiJarName,
    required String abiLibDirName,
  }) async {
    final flutterJar = File(p.join(androidDir.path, 'flutter.jar'));
    if (!flutterJar.existsSync()) return;

    final requiredFiles = [
      'flutter_embedding_release.jar',
      'flutter_embedding_release.pom',
      'flutter_embedding_release.maven-metadata.xml',
      '$abiJarName.jar',
      '$abiJarName.pom',
      '$abiJarName.maven-metadata.xml',
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
      '[engine_manager] synthesizing Android local-engine Maven artifacts '
      '($abiJarName)',
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
      final abiDir = Directory(p.join(tempDir.path, 'abi'));
      embeddingDir.createSync(recursive: true);
      Directory(p.join(abiDir.path, 'lib', abiLibDirName)).createSync(
        recursive: true,
      );

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
        p.join(tempDir.path, 'lib', abiLibDirName, 'libflutter.so'),
      );
      if (!libFlutter.existsSync()) {
        logger.detail(
          '[engine_manager] flutter.jar does not contain '
          '$abiLibDirName/libflutter.so',
        );
        return;
      }
      await libFlutter.rename(
        p.join(abiDir.path, 'lib', abiLibDirName, 'libflutter.so'),
      );

      await _createJar(
        workingDirectory: embeddingDir,
        outputPath: p.join(androidDir.path, 'flutter_embedding_release.jar'),
      );
      await _createJar(
        workingDirectory: abiDir,
        outputPath: p.join(androidDir.path, '$abiJarName.jar'),
      );

      _writePom(
        androidDir: androidDir,
        artifactId: 'flutter_embedding_release',
        version: version,
      );
      _writePom(androidDir: androidDir, artifactId: abiJarName, version: version);
      _writeMavenMetadata(
        androidDir: androidDir,
        artifactId: 'flutter_embedding_release',
        version: version,
      );
      _writeMavenMetadata(
        androidDir: androidDir,
        artifactId: abiJarName,
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
      if (!platform.isWindows) {
        for (final rel in [
          p.join('host_release', _genSnapshotFileName()),
          p.join('android_release_arm64', _genSnapshotFileName()),
          // armeabi-v7a（可选，多 ABI engine 包）
          p.join('android_release', 'universal', _genSnapshotFileName()),
        ]) {
          final genSnapshot = File(p.join(engineDir.path, rel));
          if (genSnapshot.existsSync()) {
            await Process.run('chmod', ['+x', genSnapshot.path]);
          }
        }
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
