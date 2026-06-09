import 'package:json_annotation/json_annotation.dart';

part 'patchwing_yaml.g.dart';

/// The patch verification mode for the app.
@JsonEnum(fieldRename: FieldRename.snake)
enum PatchVerification {
  /// Verify the patch signature and hash before installing and loading.
  strict,

  /// Verify the patch signature and hash before installing, but not when
  /// loading from cache.
  installOnly,
}

/// {@template patchwing_yaml}
/// A Patchwing configuration file which contains metadata about the app.
/// {@endtemplate}
@JsonSerializable(anyMap: true, disallowUnrecognizedKeys: true)
class PatchwingYaml {
  /// {@macro patchwing_yaml}
  const PatchwingYaml({
    required this.appId,
    this.flavors,
    this.baseUrl,
    this.storageBaseUrl,
    this.autoUpdate,
    this.patchVerification,
  });

  /// Creates a [PatchwingYaml] from a JSON map.
  factory PatchwingYaml.fromJson(Map<dynamic, dynamic> json) =>
      _$PatchwingYamlFromJson(json);

  /// Converts this [PatchwingYaml] to a JSON map.
  Map<String, dynamic> toJson() => _$PatchwingYamlToJson(this);

  /// The base app id.
  ///
  /// Example:
  /// `"8d3155a8-a048-4820-acca-824d26c29b71"`
  final String appId;

  /// A map of flavor names to app ids.
  ///
  /// Will be `null` for apps with no flavors.
  ///
  /// Example:
  /// ```json
  /// {
  ///   "development": "8d3155a8-a048-4820-acca-824d26c29b71",
  ///   "production": "d458e87a-7362-4386-9eeb-629db2af413a"
  /// }
  /// ```
  final Map<String, String>? flavors;

  /// The base url used to check for updates.
  final String? baseUrl;

  /// 自定义 artifact 存储基础 URL（CDN 根，不带尾部 `/`）。
  ///
  /// 仅影响**预编译产物下载**（engine artifact、aot-tools、patch 工具，以及
  /// flutter SDK cache tarball）。不会影响 [baseUrl]（auth / code-push）。
  ///
  /// 优先级（高到低）：
  ///   1. `--storage-url` CLI 全局参数；
  ///   2. `PATCHWING_STORAGE_URL` 环境变量；
  ///   3. patchwing.yaml 的 `storage_base_url` 字段（即本字段）；
  ///   4. 内置默认 `https://cdn.patchwing.net`。
  ///
  /// 例：`storage_base_url: https://cdn.patchwing.net`
  @JsonKey(name: 'storage_base_url')
  final String? storageBaseUrl;

  /// Whether or not to automatically update the app.
  final bool? autoUpdate;

  /// The patch verification mode for the app.
  final PatchVerification? patchVerification;
}

/// Extension on [PatchwingYaml] to get the app id for a specific flavor.
extension AppIdExtension on PatchwingYaml {
  /// Returns the app id for the given flavor.
  String getAppId({String? flavor}) {
    if (flavor == null || flavors == null) return appId;
    return flavors![flavor] ?? appId;
  }
}
