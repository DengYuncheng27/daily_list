# Android 构建与连接

本工程的 Android 调试包用于本机与手机测试，包名为 `dev.dayflow.dayflow`。最低 Android 7.0（API 24），编译与目标 API 36。

## 本次使用的构建环境

| 工具 | 版本 |
| --- | --- |
| Android Command Line Tools | 15859902 |
| Android SDK Platform | android-36，revision 2 |
| 插件附加 SDK Platform | android-35，revision 2 |
| 富文本插件附加 SDK Platform | android-34，revision 3 |
| Android Build Tools | 36.0.0 |
| Android NDK | 28.2.13676358 |
| Android SDK CMake | 3.22.1 |
| Android Gradle Plugin | 9.1.0 |
| Gradle | 9.3.1 |
| Java | OpenJDK 22 |

Android 工具来自 [Google 官方下载页](https://developer.android.com/studio)，命令行工具压缩包的 SHA-256 已对照官网验证：

```text
90ae805d20434428bffcb699c290860f19bb5f66a67e6b330067e3de801fb04a
```

本次 SDK、NDK、Gradle 缓存和 Android 用户配置均放在项目工作区的 `work/android-sdk/`，没有修改系统 PATH、全局 Android SDK 或 Flutter 配置。`local.properties` 是本机路径文件，不应加入版本控制。

## 本次验证结果

2026-10-20 已实际构建 1.1.0（versionCode 2）调试 APK。首次新版构建含新增插件用时 1 分 43 秒；正文语义适配完成后的最终增量构建用时 4 秒，产物时间为 17:46:07。本轮通过下文的 Gradle 入口运行 Flutter 编译任务，以避开本机全局 Flutter SDK 路径优先级问题。`apksigner verify` 通过 APK v2 签名验证，证书主体为 `Android Debug`。包包含 `arm64-v8a`、`armeabi-v7a` 和 `x86_64` 三种架构，并包含离线中文字体。

最终 APK 大小：208,805,913 字节。SHA-256：

```text
4a493c0e7718dc79c7a5da066cb64e791ea9da56ca9c6de16f9c27720ee20531
```

本次完成了编译、包结构和签名检查；没有向实体 Android 设备安装，也没有做实体设备运行验证。

## 构建调试 APK

先在 `client` 目录运行 `flutter pub get`，然后设置当前终端的 SDK 与 Java 路径：

```powershell
$env:ANDROID_HOME = 'C:\your-workspace\work\android-sdk'
$env:ANDROID_SDK_ROOT = $env:ANDROID_HOME
$env:ANDROID_USER_HOME = Join-Path $env:ANDROID_HOME 'user'
$env:GRADLE_USER_HOME = Join-Path $env:ANDROID_HOME 'gradle-cache'
$env:JAVA_HOME = 'C:\path\to\your-jdk'
flutter build apk --debug --no-pub
```

正常产物位于 `build/app/outputs/flutter-apk/app-debug.apk`。此 APK 使用 Android 调试证书，仅供测试，不能作为正式发行签名。将 APK 复制到手机安装，或在已授权 USB 调试的设备上执行：

```powershell
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

上述安装命令应由设备持有人在确认目标设备后运行；本次构建不会自动安装到连接的手机。

如果本机 Flutter 曾用 `flutter config --android-sdk` 设置其他 SDK，该设置会优先于 `ANDROID_HOME`，并覆盖 `android/local.properties`。本次遇到该情况，未改用户全局配置：把本机 `android/local.properties` 的 `sdk.dir` 指向工作区完整 SDK 后，在同一终端执行以下等价 Gradle 入口。它会运行 `compileFlutterBuildDebug`、打包并使用调试证书签名。

```powershell
cd android
.\gradlew.bat assembleDebug '-Ptarget=lib/main.dart' '-Ptarget-platform=android-arm,android-arm64,android-x64' '-Pbuild-mode=debug' --console=plain
```

## 手机访问服务端

在登录页展开服务器地址并填写后端地址，只填来源地址，不要添加 `/api/v1`：

- 实体手机：使用电脑的局域网 IP，例如 `http://192.168.1.20:8765`；手机与电脑应能互相访问，后端需监听局域网接口。
- Android 模拟器：通常使用 `http://10.0.2.2:8765` 访问宿主机。
- `127.0.0.1` 在手机上指手机本身，不能用它连接电脑上的服务。
- 生产部署使用 `https://你的域名`；也可通过 `--dart-define=API_BASE_URL=https://你的域名` 设定初始地址。

仅 `src/debug/AndroidManifest.xml` 允许明文 HTTP，用于局域网开发。正式构建保持 Android 的 HTTPS 默认限制。

## 正式发布

本工程保留 Flutter 初始模板的 release 签名占位设置；其中的调试证书不是发布证书。正式发布前必须使用发行方自己的 keystore 配置 `signingConfigs`，替换 `app/build.gradle.kts` 的调试签名占位，并妥善保存密钥与密码。不要提交 keystore、密码或 `key.properties`。

配置正式签名、HTTPS 服务地址并完成设备验证后，再构建发布 APK 或 AAB。iOS 签名、商店发布和设备实测不属于此 Android 构建记录。
