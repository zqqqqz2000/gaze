# Gaze Demo Apps

`demo/` 里现在有两端：

- `GazeDemoApp`：iPhone 真机 provider，负责采集 `ARKit` gaze sample 并推流
- `GazeBeamHost`：macOS host，负责接收 sample、做 9 点校准，并在屏幕最上层渲染 gaze overlay

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

### iPhone Demo

- 启动 / 停止 `GazeProvider`
- 展示 provider state
- 展示最新 sample 的 confidence、face distance、gaze origin、gaze dir
- 可选连接 host IP + port，发送 sample stream

### macOS Host

- 监听 `9000` 端口接收 iPhone sample
- 在屏幕最上层渲染半透明 beam overlay
- overlay 不抢焦点，鼠标事件直接穿透
- 9 点校准
- 自动保存上一次成功的校准参数，并在下次启动时恢复

## 端到端校准步骤

1. 先启动 `GazeBeamHost`
2. 记下 host 窗口里显示的本机 IP，例如 `192.168.x.x:9000`
3. 在 iPhone `GazeDemoApp` 里填入同样的 host 和 port
4. iPhone 开始 tracking，并开启 stream
5. 在 Mac 端点击 `Start Calibration`
6. 依次盯住屏幕上出现的 9 个校准点，等待每个点自动采样完成
7. 状态显示 `calibration complete` 后，host 会自动保存本次校准

如果要重新做校准，点击 `Clear Calibration` 后再重新开始。

## 常见问题

- 如果 `Start Tracking` 报错 `ARFaceTracking not supported`，说明设备不支持
- 如果 app 能启动但没有 sample，多半是没授权相机，或前摄没有看到人脸
- 如果网络流发不出去，先确认 iPhone 和 Mac 在同一网段
- 如果 host 没有响应校准，先看 `Log` 区域里是否已经收到 `first streamed sample received`
