## Patchwing 🐦

[![Discord](https://img.shields.io/discord/1030243211995791380?style=for-the-badge&logo=discord&color=blue)](https://discord.gg/patchwing)
<a href="https://www.producthunt.com/posts/patchwing-code-push?utm_source=badge-featured&utm_medium=badge&utm_souce=badge-patchwing&#0045;code&#0045;push" target="_blank"><img src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=449946&theme=neutral" alt="Patchwing&#0032;Code&#0032;Push - Flutter&#0032;over&#0032;the&#0032;air&#0032;updates | Product Hunt" style="width: 128px; height: 27px;" width="128" height="27" /></a>

[![patchwing ci](https://api.patchwing.dev/api/v1/github/patchwingtech/patchwing/badge.svg)](https://console.patchwing.dev/ci)
[![ci](https://github.com/patchwingtech/patchwing/actions/workflows/main.yaml/badge.svg)](https://github.com/patchwingtech/patchwing/actions/workflows/main.yaml)
[![e2e](https://github.com/patchwingtech/patchwing/actions/workflows/e2e.yaml/badge.svg)](https://github.com/patchwingtech/patchwing/actions/workflows/e2e.yaml)
[![codecov](https://codecov.io/gh/patchwingtech/patchwing/branch/main/graph/badge.svg)](https://codecov.io/gh/patchwingtech/patchwing)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](./LICENSE-MIT)
[![License: Apache](https://img.shields.io/badge/license-Apache-orange.svg)](./LICENSE-APACHE)

## Getting Started

Visit https://docs.patchwing.dev to get started.

## Packages

This repository is a monorepo containing the following packages:

| Package                                                                         | Description                                                                             |
| ------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| [patchwing_cli](packages/patchwing_cli/README.md)                               | Command-line which allows developers to interact with various Patchwing services        |
| [patchwing_code_push_client](packages/patchwing_code_push_client/README.md)     | Dart library which allows Dart applications to interact with the Patchwing CodePush API |
| [patchwing_code_push_protocol](packages/patchwing_code_push_protocol/README.md) | Dart library which contains common interfaces used by Patchwing CodePush                |
| [artifact_proxy](packages/artifact_proxy/README.md)                             | Dart server which supports intercepting and proxying Flutter artifact requests          |
| [discord_gcp_alerts](packages/discord_gcp_alerts/README.md)                     | Dart server which forwards GCP alerts to Discord                                        |
| [flutter_version_resolver](packages/flutter_version_resolver/README.md)         | Command-line utility that determines which Flutter version should be used for a project |
| [jwt](packages/jwt/README.md)                                                   | Dart library for verifying JSON Web Tokens                                              |
| [redis_client](packages/redis_client/README.md)                                 | Dart library for interacting with Redis                                                 |
| [scoped_deps](packages/scoped_deps/README.md)                                   | A simple dependency injection library built on Zones                                    |
| [stripe_api](packages/stripe_api/README.md)                                     | Dart library for interacting with Stripe                                                |

For more information, please refer to the documentation for each package.

## Contributing

If you're interested in contributing, please join us on
[Discord](https://discord.gg/patchwing).

### Environment setup

Working on Patchwing requires Dart.

`./scripts/bootstrap.sh` will run `pub get` all packages in the repository.

### Running tests

We don't yet have a script to run tests locally. For now, we recommend using
`very_good test -r` in the packages directory to run all patchwing tests.

(If you run it in the root, it will find packages in bin/cache/flutter and try
to run tests there, some of which will fail.)

To generate a coverage report install `lcov`:

```
brew install lcov
```

Then run tests with the `--coverage` flag:

```
very_good test -r --coverage
genhtml coverage/lcov.info -o coverage
```

You can view the generated coverage report via:

```
open coverage/index.html
```

### Tracking coverage

The following command will generate a coverage report for the Dart packages:

```bash
dart test --coverage=coverage && dart pub global run coverage:format_coverage --lcov --in=coverage --out=coverage/lcov.info --packages=.dart_tool/package_config.json --check-ignore
```

Coverage reports are uploaded to [Codecov](https://app.codecov.io/gh/patchwingtech/patchwing).

## License

Patchwing projects are licensed for use under either Apache License, Version 2.0
(LICENSE-APACHE or http://www.apache.org/licenses/LICENSE-2.0) MIT license
(LICENSE-MIT or http://opensource.org/licenses/MIT) at your option.

See our license philosophy for more information on why we license files this
way:
https://handbook.patchwing.dev/engineering/#licensing-philosophy
