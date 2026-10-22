# 日序 Dayflow 客户端

Flutter 3.47.7 / Dart 3.13.5，包含 Windows、Web、Android 和 iOS 工程。

完整的启动、服务器地址、四端构建、云同步和部署说明见 [项目 README](../README.md)。服务 API 与同步字段见 [API_CONTRACT.md](../API_CONTRACT.md)。

在本目录运行：

```sh
flutter pub get
flutter analyze
flutter test
flutter run -d windows
```

Web 本机预览先执行 `flutter build web --release`，再从项目根目录运行 `python scripts/preview.py --api http://127.0.0.1:8000`。

平台工程和 CI 配置不等于已完成四端原生验证；实际结果见根目录 README 的检查记录。iOS 编译与发布需要 macOS、Xcode 和相应签名配置。
