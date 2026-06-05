import 'package:meta/meta.dart';
import 'package:patchwing_code_push_protocol/model_helpers.dart';
import 'package:patchwing_code_push_protocol/src/models/patch_artifact.dart';

/// {@template get_patch_artifacts_response}
/// The response body for GET /apps/{appId}/patches/{patchId}/artifacts.
/// {@endtemplate}
@immutable
class GetPatchArtifactsResponse {
  /// {@macro get_patch_artifacts_response}
  const GetPatchArtifactsResponse({
    required this.artifacts,
  });

  /// Converts a `Map<String, dynamic>` to a [GetPatchArtifactsResponse].
  factory GetPatchArtifactsResponse.fromJson(Map<String, dynamic> json) {
    return parseFromJson(
      'GetPatchArtifactsResponse',
      json,
      () => GetPatchArtifactsResponse(
        artifacts: (json['artifacts'] as List)
            .map<PatchArtifact>(
              (e) => PatchArtifact.fromJson(e as Map<String, dynamic>),
            )
            .toList(),
      ),
    );
  }

  /// Convenience to create a nullable type from a nullable json object.
  /// Useful when parsing optional fields.
  static GetPatchArtifactsResponse? maybeFromJson(
    Map<String, dynamic>? json,
  ) {
    if (json == null) {
      return null;
    }
    return GetPatchArtifactsResponse.fromJson(json);
  }

  /// The artifacts for the patch.
  final List<PatchArtifact> artifacts;

  /// Converts a [GetPatchArtifactsResponse] to a `Map<String, dynamic>`.
  Map<String, dynamic> toJson() {
    return {
      'artifacts': artifacts.map((e) => e.toJson()).toList(),
    };
  }

  @override
  int get hashCode => listHash(artifacts).hashCode;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is GetPatchArtifactsResponse &&
        listsEqual(artifacts, other.artifacts);
  }
}
