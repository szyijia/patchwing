import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:scoped_deps/scoped_deps.dart';

/// A reference to a [PatchwingVersion] instance.
final patchwingVersionRef = create(PatchwingVersion.new);

/// The [PatchwingVersion] instance available in the current zone.
PatchwingVersion get patchwingVersion => read(patchwingVersionRef);

/// 编译时通过 `dart compile exe -D PATCHWING_BUILD_VERSION=<x.y.z>+<sha>`
/// 注入。本地手工编译（不传 -D）时为 `dev`，此时跳过版本检查。
const String _kBuildVersion = String.fromEnvironment(
  'PATCHWING_BUILD_VERSION',
  defaultValue: 'dev',
);

/// 编译期注入的构建版本（`dev` 表示本地手工编译未注入）。
/// 导出给 command_runner 的 `pw --version` 显示使用。
const String patchwingBuildVersion = _kBuildVersion;

/// CDN 上发布的 latest 版本号文件。
/// CI 在发布二进制时同步写入：
///   https://cdn.patchwing.net/patchwing/cli/latest/version.txt
const String _kLatestVersionUrl =
    'https://cdn.patchwing.net/patchwing/cli/latest/version.txt';

/// {@template patchwing_version}
/// Provides information about installed and available versions of Patchwing.
///
/// Patchwing 的 `pw` 是预编译二进制（通过 `install.sh` 从 CDN 下载安装），
/// **不是 git clone**，所以 Shorebird 上游基于 `git rev-parse HEAD` /
/// `git reset --hard` 的版本检查与升级逻辑对我们都不适用。
///
/// 这里的实现：
///   - 本地版本：编译期通过 `-D PATCHWING_BUILD_VERSION=...` 注入。
///   - 远端版本：HTTP GET CDN 上的 `version.txt`。
///   - 升级动作：不再做 in-place 升级，而是提示用户重新执行 `install.sh`。
/// {@endtemplate}
class PatchwingVersion {
  /// {@macro patchwing_version}
  PatchwingVersion();

  /// HTTP 请求超时（秒）。
  static const _kHttpTimeout = Duration(seconds: 5);

  /// Whether the current version of Patchwing is the latest available.
  ///
  /// 当本地是 `dev` 构建（未注入版本号）时，返回 `true` 以跳过检查，避免
  /// 开发者本地反复构建时被打扰；CI 编译产物会注入真实版本号。
  Future<bool> isLatest() async {
    if (_kBuildVersion == 'dev') {
      return true;
    }
    final currentVersion = await fetchCurrentVersion();
    final latestVersion = await fetchLatestVersion();
    return currentVersion == latestVersion;
  }

  /// 返回 CDN 上发布的最新版本号字符串。
  ///
  /// 网络异常一律抛 [ProcessException]（沿用上游签名，避免上层
  /// `on ProcessException` 调用点改动过大）。
  Future<String> fetchLatestVersion() async {
    try {
      final response = await http
          .get(Uri.parse(_kLatestVersionUrl))
          .timeout(_kHttpTimeout);
      if (response.statusCode != 200) {
        throw ProcessException(
          'http',
          [_kLatestVersionUrl],
          'GET $_kLatestVersionUrl returned ${response.statusCode}',
          response.statusCode,
        );
      }
      return response.body.trim();
    } on TimeoutException {
      throw ProcessException(
        'http',
        [_kLatestVersionUrl],
        'GET $_kLatestVersionUrl timed out',
      );
    } on http.ClientException catch (e) {
      throw ProcessException('http', [_kLatestVersionUrl], e.message);
    } on SocketException catch (e) {
      throw ProcessException('http', [_kLatestVersionUrl], e.message);
    }
  }

  /// 返回当前可执行文件的版本号（编译期注入）。
  Future<String> fetchCurrentVersion() async => _kBuildVersion;

  /// 是否跟踪 stable 通道。
  ///
  /// 预编译二进制不再有 git 分支的概念，统一视作跟踪 stable，
  /// 这样 [`_checkForUpdates`](command_runner) 仍会调用 [isLatest]，
  /// 但 `isLatest` 内部已对 dev 模式短路。
  Future<bool> isTrackingStable() async => true;

  // ---- 兼容旧 API（保留方法名，转发到新实现） -------------------------------

  /// @deprecated Use [fetchCurrentVersion]. 保留是为了兼容 build_environment
  /// 等其他模块的旧调用，新代码请勿使用。
  Future<String> fetchCurrentGitHash() => fetchCurrentVersion();

  /// @deprecated Use [fetchLatestVersion]. 同上。
  Future<String> fetchLatestGitHash() => fetchLatestVersion();
}
