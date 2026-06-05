# Artifact Proxy

This is a tool for proxying Flutter artifacts from a derived Flutter engine
revision back to the base Flutter engine revision. This is useful for
when you need to modify _some_ of the Flutter artifacts but not all of them.

This is a development tool which map requests to Google
Storage (either Patchwing's bucket or the official Flutter buckets).

## Usage

Uses `config.dart` to configure the engine revisions and artifact overrides.

```bash
# Run locally with hot-reload enabled.
DEV=true dart --enable-vm-service run bin/server.dart
```

And then in a separate terminal:

```
FLUTTER_STORAGE_BASE_URL=http://localhost:8080 flutter precache -a
```

You should use a separate checkout of Flutter when running this, so you don't
poison the cache of your main Flutter checkout.

## Updating config.dart

If run into 404s when fetching artifacts, ensure that the expected manifest
exists at
https://storage.googleapis.com/cdn.patchwing.net/patchwing/$engineRevision/artifacts_manifest.yaml.

If it does, you may need to update the artifact list in `config.dart` and, if
the artifact is one we're providing, add it in `tool/generate_manifest.sh`

To do so, you will need to determine the artifact URLs. Follow these steps:

- Adjust patchwing_cli to point to http://localhost:8080 instead of https://cdn.patchwing.net:

  - packages\patchwing_cli\lib\src\patchwing_process.dart

    ```diff
        Map<String, String> _environmentOverrides({
        required String executable,
    }) {
        if (executable == 'flutter') {
        // If this ever changes we also need to update the `patchwing` shell
        // wrapper which downloads runs Flutter to fetch artifacts the first time.
    -      return {'FLUTTER_STORAGE_BASE_URL': 'https://cdn.patchwing.net'};
    +      return {'FLUTTER_STORAGE_BASE_URL': 'http://localhost:8080'};
        }

        return {};
    }
    ```

- Adjust third_party Flutter to point to http://localhost:8080 instead of https://cdn.patchwing.net:

  - third_party\flutter\bin\internal\shared.sh

    ```diff
    # Either clones or pulls the Patchwing Flutter repository, depending on whether FLUTTER_PATH exists.
    function update_flutter {
    if [[ -d "$FLUTTER_PATH" ]]; then
        git -C "$FLUTTER_PATH" fetch
    else
        git clone --filter=tree:0 https://github.com/patchwingtech/flutter.git --no-checkout "$FLUTTER_PATH"
    fi
    # -c to avoid printing a warning about being in a detached head state.
    git -C "$FLUTTER_PATH" -c advice.detachedHead=false checkout "$FLUTTER_VERSION"
    PATCHWING_ENGINE_VERSION=`cat "$FLUTTER_PATH/bin/internal/engine.version"`
    echo "Patchwing Engine • revision $PATCHWING_ENGINE_VERSION"
    # Install Patchwing Flutter Artifacts
    -  FLUTTER_STORAGE_BASE_URL=https://cdn.patchwing.net $FLUTTER_PATH/bin/flutter --version
    +  FLUTTER_STORAGE_BASE_URL=http://localhost:8080 $FLUTTER_PATH/bin/flutter --version
    }
    ```

- Modify flutter_tool used by Patchwing to allow downloads from insecure URLs:
  - patchwing\bin\cache\flutter\packages\flutter_tools\gradle\flutter.gradle
    ```diff
    rootProject.allprojects {
        repositories {
            maven {
                url repository
    +           allowInsecureProtocol true
            }
        }
    }
    ```
- Remove the flutter_tools snapshot

  ```bash
  cd bin/cache/flutter/bin/cache
  rm flutter_tools.s*
  ```

- Run a patchwing command (`patchwing run` works well)
- For each artifact that 404s, add a line to `packages\artifact_proxy\lib\config.dart`, following the conventions for capturing engine revisions and escaping relevant characters.

## Generating an `artifact_manifest.yaml`

To generate a new `artifact_manifest.yaml` for a specific flutter_revision use the following command:

```
./tools/generate_manifest.sh <flutter_engine_revision> > artifact_manifest.yaml
```

Then upload the `artifact_manifest.yaml` to `cdn.patchwing.net/patchwing/<patchwing_engine_revision>/artifacts_manifest.yaml`
