# HollowTone - Release Builds

本分支（`release`）仅存放 HollowTone 客户端的编译产物，源码见 `master` 分支。

## 版本 v1.1.0 (build 50)

| 文件 | 大小 | 适用设备 |
|---|---|---|
| `HollowTone-v1.1.0-arm64-v8a.apk` | 31.4 MB | 绝大多数现代 Android 手机（推荐） |
| `HollowTone-v1.1.0-armeabi-v7a.apk` | 28.7 MB | 老旧 32 位 ARM 设备 |
| `HollowTone-v1.1.0-x86_64.apk` | 33.7 MB | Android 模拟器 / x86 平板 |
| `HollowTone-v1.1.0-universal.apk` | 90.5 MB | 通用包，不确定架构时用这个 |
| `SHA256SUMS.txt` | - | 各 APK 的 SHA-256 校验值 |

## 安装

```bash
adb install HollowTone-v1.1.0-arm64-v8a.apk
```

或直接把 APK 传到手机点击安装（需允许「安装未知来源应用」）。

## 校验

```bash
sha256sum -c SHA256SUMS.txt
```
