## Patchwing CodePush Protocol

The Patchwing CodePush Protocol is a Dart library which contains common interfaces used by Patchwing CodePush.

### Regenerating from the OpenAPI spec

Everything under `lib/src/` is generated from the public Patchwing
CodePush OpenAPI spec at [api.patchwing.net/openapi.json](https://api.patchwing.net/openapi.json)
(also served as [openapi.yaml](https://api.patchwing.net/openapi.yaml)
for easier human review) by
[space_gen](https://github.com/eseidel/space_gen). To regenerate
against the latest published spec:

```sh
dart run packages/patchwing_code_push_protocol/tool/gen.dart \
  -i https://api.patchwing.net/openapi.json \
  -o packages/patchwing_code_push_protocol
```

Hand-written files (`lib/extensions/`, `lib/patchwing_code_push_protocol.dart`)
are left untouched by the generator. The version of space_gen in use is
pinned in `pubspec.yaml`.
