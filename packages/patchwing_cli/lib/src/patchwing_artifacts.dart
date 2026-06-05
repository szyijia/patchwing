// Allowing one member abstracts for consistency/namespace/ease of testing.
// ignore_for_file: one_member_abstracts

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:patchwing_cli/src/cache.dart';
import 'package:patchwing_cli/src/engine_config.dart';
import 'package:patchwing_cli/src/patchwing_env.dart';

/// All Patchwing artifacts used explicitly by Patchwing.
enum PatchwingArtifact {
  /// The iOS analyze_snapshot executable.
  analyzeSnapshotIos,

  /// The macOS analyze_snapshot executable.
  analyzeSnapshotMacOS,

  /// The aot_tools executable or kernel file.
  aotTools,

  /// The gen_snapshot executable for iOS.
  genSnapshotIos,

  /// The gen_snapshot executable for macOS that creates arm64 snapshots.
  genSnapshotMacosArm64,

  /// The gen_snapshot executable for macOS that creates x64 snapshots.
  genSnapshotMacosX64,
}

/// A reference to a [PatchwingArtifacts] instance.
final patchwingArtifactsRef = create<PatchwingArtifacts>(
  PatchwingCachedArtifacts.new,
);

/// The [PatchwingArtifacts] instance available in the current zone.
PatchwingArtifacts get patchwingArtifacts => read(patchwingArtifactsRef);

/// {@template patchwing_artifacts}
/// A class that provides access to Patchwing artifacts.
/// {@endtemplate}
abstract class PatchwingArtifacts {
  /// Returns the path to the given [artifact].
  String getArtifactPath({required PatchwingArtifact artifact});
}

/// {@template patchwing_cached_artifacts}
/// A class that provides access to cached Patchwing artifacts.
/// {@endtemplate}
class PatchwingCachedArtifacts implements PatchwingArtifacts {
  /// {@macro patchwing_cached_artifacts}
  const PatchwingCachedArtifacts();

  @override
  String getArtifactPath({required PatchwingArtifact artifact}) {
    switch (artifact) {
      case PatchwingArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case PatchwingArtifact.analyzeSnapshotMacOS:
        return _analyzeSnapshotMacosFile.path;
      case PatchwingArtifact.aotTools:
        return _aotToolsFile.path;
      case PatchwingArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case PatchwingArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacOsArm64File.path;
      case PatchwingArtifact.genSnapshotMacosX64:
        return _genSnapshotMacOsX64File.path;
    }
  }

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File get _analyzeSnapshotMacosFile {
    return File(
      p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'analyze_snapshot',
      ),
    );
  }

  File get _aotToolsFile {
    const executableName = 'aot-tools';
    final kernelFile = File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        patchwingEnv.patchwingEngineRevision,
        '$executableName.dill',
      ),
    );
    if (kernelFile.existsSync()) {
      return kernelFile;
    }

    // We shipped aot-tools as an executable in the past, so we return that if
    // no kernel file is found.
    return File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        patchwingEnv.patchwingEngineRevision,
        executableName,
      ),
    );
  }

  File get _genSnapshotIosFile {
    return File(
      p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsArm64File {
    return File(
      p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsX64File {
    return File(
      p.join(
        patchwingEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_x64',
      ),
    );
  }
}

/// {@template patchwing_local_engine_artifacts}
/// A class that provides access to locally built Patchwing artifacts.
/// {@endtemplate}
class PatchwingLocalEngineArtifacts implements PatchwingArtifacts {
  /// {@macro patchwing_local_engine_artifacts}
  const PatchwingLocalEngineArtifacts();

  @override
  String getArtifactPath({required PatchwingArtifact artifact}) {
    switch (artifact) {
      case PatchwingArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case PatchwingArtifact.analyzeSnapshotMacOS:
        return _analyzeSnapshotMacosFile.path;
      case PatchwingArtifact.aotTools:
        return _aotToolsFile.path;
      case PatchwingArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case PatchwingArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacosArm64File.path;
      case PatchwingArtifact.genSnapshotMacosX64:
        return _genSnapshotMacosX64File.path;
    }
  }

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File get _analyzeSnapshotMacosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'analyze_snapshot',
      ),
    );
  }

  File get _aotToolsFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'flutter',
        'third_party',
        'dart',
        'pkg',
        'aot_tools',
        'bin',
        'aot_tools.dart',
      ),
    );
  }

  File get _genSnapshotIosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacosArm64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_arm64',
        'gen_snapshot',
      ),
    );
  }

  File get _genSnapshotMacosX64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_x64',
        'gen_snapshot',
      ),
    );
  }
}
