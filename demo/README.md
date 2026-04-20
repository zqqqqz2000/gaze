# Gaze Demo App

`demo/` 里提供一个最小 iPhone demo app，用来真机调试 `GazeProviderKit`。

## 打开方式

优先用 `xcodegen` 生成工程：

```bash
cd demo
xcodegen generate
```

然后在 Xcode 中打开：

```text
demo/GazeDemoApp.xcodeproj
```

工程通过本地 package 依赖当前仓库根目录。

## 运行要求

- 需要支持 `ARFaceTrackingConfiguration` 的 iPhone 真机
- 需要相机权限
- 不能用模拟器验证真实 face tracking

## USB 是否必须

不是功能上必须，但**第一次部署和调试时建议用 USB**：

- 第一次装 app 到手机，USB 最稳
- 第一次建立信任关系，USB 最稳
- 如果你已经在 Xcode 里配好了无线调试，后续可以不用 USB

对 gaze stream 本身来说，**不需要 USB**。如果后面要把样本发回 Mac，走同一局域网即可。

## Demo 功能

- 启动 / 停止 `GazeProvider`
- 展示 provider state
- 展示最新 sample 的 confidence、face distance、gaze origin、gaze dir
- 可选连接 host IP + port，发送 sample stream

## 常见问题

- 如果 `Start Tracking` 报错 `ARFaceTracking not supported`，说明设备不支持
- 如果 app 能启动但没有 sample，多半是没授权相机，或前摄没有看到人脸
- 如果网络流发不出去，先确认 iPhone 和 Mac 在同一网段
