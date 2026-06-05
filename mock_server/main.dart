import 'dart:convert';
import 'dart:io';

/// 本地 Mock API 服务器，用于调通 Patchwing CLI
/// 支持认证、app 创建、release/patch 上传等流程
Future<void> main() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 8080);
  print('Mock API Server running at http://localhost:8080');

  // 内存存储
  final apps = <String, Map<String, dynamic>>{};
  final releases = <String, List<Map<String, dynamic>>>{};
  final patches = <String, List<Map<String, dynamic>>>{};
  var appIdCounter = 1;
  var releaseIdCounter = 1;
  var patchIdCounter = 1;

  await for (final request in server) {
    final path = request.uri.path;
    final method = request.method;

    print('${DateTime.now()} $method $path');

    // 添加 CORS 头
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add(
      'Access-Control-Allow-Methods',
      'GET, POST, PUT, DELETE, OPTIONS',
    );
    request.response.headers.add(
      'Access-Control-Allow-Headers',
      'Authorization, Content-Type',
    );

    if (method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      continue;
    }

    // 验证认证（除了特定端点）
    final authHeader = request.headers.value('Authorization');
    if (authHeader == null || !authHeader.startsWith('Bearer ')) {
      // 某些端点可能不需要认证
    }

    try {
      // API v1 路由
      if (path == '/api/v1/users/me') {
        // 获取当前用户信息
        await _handleGetCurrentUser(request);
      } else if (path == '/api/v1/organizations') {
        // 获取组织列表
        await _handleGetOrganizations(request);
      } else if (path == '/api/v1/apps' && method == 'POST') {
        // 创建应用
        await _handleCreateApp(request, apps, () => appIdCounter++);
      } else if (path == '/api/v1/apps' && method == 'GET') {
        // 获取应用列表
        await _handleGetApps(request, apps);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.endsWith('/releases') &&
          method == 'POST') {
        // 创建 release
        await _handleCreateRelease(request, releases, () => releaseIdCounter++);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.endsWith('/releases') &&
          method == 'GET') {
        // 获取 release 列表
        await _handleGetReleases(request, releases);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.contains('/releases/') &&
          path.endsWith('/artifacts')) {
        // 创建 release artifact（返回 signed URL）
        await _handleCreateReleaseArtifact(request);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.endsWith('/patches') &&
          method == 'POST') {
        // 创建 patch
        await _handleCreatePatch(request, patches, () => patchIdCounter++);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.contains('/patches/') &&
          path.endsWith('/artifacts')) {
        // 创建 patch artifact（返回 signed URL）
        await _handleCreatePatchArtifact(request);
      } else if (path.startsWith('/api/v1/apps/') &&
          path.endsWith('/channels') &&
          method == 'POST') {
        // 创建 channel
        await _handleCreateChannel(request);
      } else {
        // 404
        request.response.statusCode = HttpStatus.notFound;
        await _writeJson(request, {'error': 'Not found'});
      }
    } catch (e, stack) {
      print('Error handling request: $e');
      print(stack);
      request.response.statusCode = HttpStatus.internalServerError;
      await _writeJson(request, {'error': e.toString()});
    }
  }
}

// 处理获取当前用户
Future<void> _handleGetCurrentUser(HttpRequest request) async {
  await _writeJson(request, {
    'id': 1,
    'email': 'dev@patchwing.local',
    'name': 'Local Developer',
  });
}

// 处理获取组织列表
Future<void> _handleGetOrganizations(HttpRequest request) async {
  final now = DateTime.now().toIso8601String();
  await _writeJson(request, {
    'organizations': [
      {
        'organization': {
          'id': 1,
          'name': 'Default Organization',
          'organization_type': 'personal',
          'created_at': now,
          'updated_at': now,
        },
        'role': 'admin',
      },
    ],
  });
}

// 处理创建应用
Future<void> _handleCreateApp(
  HttpRequest request,
  Map<String, Map<String, dynamic>> apps,
  int Function() nextId,
) async {
  final body = await _readJson(request);
  final displayName = body['display_name'] as String? ?? 'Unnamed App';
  final appId = 'app-${nextId()}';

  apps[appId] = {
    'id': appId,
    'display_name': displayName,
    'organization_id': body['organization_id'],
    'created_at': DateTime.now().toIso8601String(),
  };

  print('Created app: $appId - $displayName');
  await _writeJson(request, apps[appId]!);
}

// 处理获取应用列表
Future<void> _handleGetApps(
  HttpRequest request,
  Map<String, Map<String, dynamic>> apps,
) async {
  await _writeJson(request, {
    'apps': apps.values.toList(),
  });
}

// 处理创建 release
Future<void> _handleCreateRelease(
  HttpRequest request,
  Map<String, List<Map<String, dynamic>>> releases,
  int Function() nextId,
) async {
  final body = await _readJson(request);
  final appId = _extractAppId(request.uri.path);
  final releaseId = nextId();

  final release = {
    'id': releaseId,
    'app_id': appId,
    'version': body['version'] ?? '1.0.0',
    'platform': body['platform'] ?? 'android',
    'flutter_revision': body['flutter_revision'] ?? 'unknown',
    'display_name': body['display_name'] ?? 'Release $releaseId',
    'created_at': DateTime.now().toIso8601String(),
  };

  releases.putIfAbsent(appId, () => []).add(release);
  print('Created release: $releaseId for app $appId');
  await _writeJson(request, release);
}

// 处理获取 release 列表
Future<void> _handleGetReleases(
  HttpRequest request,
  Map<String, List<Map<String, dynamic>>> releases,
) async {
  final appId = _extractAppId(request.uri.path);
  final appReleases = releases[appId] ?? [];
  await _writeJson(request, {
    'releases': appReleases,
  });
}

// 处理创建 release artifact
Future<void> _handleCreateReleaseArtifact(HttpRequest request) async {
  final body = await _readJson(request);
  final artifactId = DateTime.now().millisecondsSinceEpoch;

  // 返回一个本地文件系统的 signed URL（模拟）
  final localPath = '/tmp/patchwing_artifacts/release_$artifactId.bin';
  await _writeJson(request, {
    'id': artifactId,
    'url': 'file://$localPath',
    'fields': {},
  });
}

// 处理创建 patch
Future<void> _handleCreatePatch(
  HttpRequest request,
  Map<String, List<Map<String, dynamic>>> patches,
  int Function() nextId,
) async {
  final body = await _readJson(request);
  final appId = _extractAppId(request.uri.path);
  final patchId = nextId();

  final patch = {
    'id': patchId,
    'app_id': appId,
    'release_id': body['release_id'],
    'number': patchId,
    'created_at': DateTime.now().toIso8601String(),
  };

  patches.putIfAbsent(appId, () => []).add(patch);
  print('Created patch: $patchId for app $appId');
  await _writeJson(request, patch);
}

// 处理创建 patch artifact
Future<void> _handleCreatePatchArtifact(HttpRequest request) async {
  final body = await _readJson(request);
  final artifactId = DateTime.now().millisecondsSinceEpoch;

  // 返回一个本地文件系统的 signed URL（模拟）
  final localPath = '/tmp/patchwing_artifacts/patch_$artifactId.bin';
  await _writeJson(request, {
    'id': artifactId,
    'url': 'file://$localPath',
    'fields': {},
  });
}

// 处理创建 channel
Future<void> _handleCreateChannel(HttpRequest request) async {
  final body = await _readJson(request);
  await _writeJson(request, {
    'id': DateTime.now().millisecondsSinceEpoch,
    'name': body['channel'] ?? 'stable',
    'app_id': _extractAppId(request.uri.path),
  });
}

// 辅助函数：提取 app_id
String _extractAppId(String path) {
  final parts = path.split('/');
  final appsIndex = parts.indexOf('apps');
  if (appsIndex >= 0 && appsIndex + 1 < parts.length) {
    return parts[appsIndex + 1];
  }
  return 'unknown';
}

// 辅助函数：读取 JSON
Future<Map<String, dynamic>> _readJson(HttpRequest request) async {
  final body = await utf8.decoder.bind(request).join();
  if (body.isEmpty) return {};
  return json.decode(body) as Map<String, dynamic>;
}

// 辅助函数：写入 JSON
Future<void> _writeJson(HttpRequest request, Map<String, dynamic> data) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(json.encode(data));
  await request.response.close();
}
