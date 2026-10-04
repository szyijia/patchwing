# Patchwing

Flutter 应用的 release 与静默 Dart patch 工具。安装入口：[patchwing.net](https://patchwing.net)；使用文档：[docs.patchwing.net](https://docs.patchwing.net)。

## 开发环境

需要 Git、与项目约束兼容的 Flutter/Dart 开发环境，以及目标平台的正常原生工具链：Android SDK/JDK；iOS 使用 macOS、Xcode 和有效的开发者签名条件。CLI 下载配套的预编译 SDK，应用开发者不需要私有 Dart 源码或自行编译 engine。

## 安装与标准流程

从官网取得安装脚本并执行；脚本使用本仓库的公开默认分支：

```bash
curl -fsSL https://patchwing.net/install.sh -o patchwing-install.sh
bash patchwing-install.sh
pw --version
pw create my_app --org com.example --platforms android,ios
cd my_app
pw release --platforms=android --artifact=apk
pw release --platforms=ios --export-method=development
```

`development` 用于开发签名的 Release IPA，不代表 App Store 分发。正式分发须按对应平台的签名和发布要求配置。

应用代码修改后，对已有 release 发布 patch：

```bash
pw patch --platforms=android --release-version=1.0.0+1
pw patch --platforms=ios --release-version=1.0.0+1
```

release-version 必须与实际基线相同。默认自动更新在原安装中检查和下载 patch，下一次正常冷启动激活；不得用安装一个新 APK/IPA 来代替 patch 验证。

`pw help` 查看全部命令；`pw <command> --help` 查看具体参数。

## 源码与贡献

本仓库包含 CLI、服务客户端、协议和相关 Dart 工具。既有内部包目录名与接口保留，以避免改动运行逻辑。开发者入口是 `pw`。

在兼容的 Dart SDK 环境中，按仓库锁定依赖运行对应包的测试：

```bash
dart pub get --enforce-lockfile
cd packages/shorebird_cli
dart test test/src/commands/init_command_test.dart
```

## 许可证

代码遵循 [Apache-2.0](LICENSE-APACHE) 或 [MIT](LICENSE-MIT) 双许可证。原始许可证和源码版权声明保留。
