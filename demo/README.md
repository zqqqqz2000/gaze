# Gaze Demo Apps

`demo/` 里现在有三端：

- `GazeDemoApp`：iPhone 真机 provider，负责采集 `ARKit` gaze sample 并推流
- `GazeBeamHost`：macOS host，负责接收 sample、做 9 点校准，并在屏幕最上层渲染 gaze overlay
- `windows/GazeWinHost`：Windows host，负责接收 LAN sample，并渲染和 macOS 风格一致的透明 beam overlay

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

Windows host 使用 CMake 构建：

```powershell
cd demo/windows
cmake -S . -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

## 运行要求

- 需要支持 `ARFaceTrackingConfiguration` 的 iPhone 真机
- 需要相机权限
- 不能用模拟器验证真实 face tracking

## 连接方式

现在 demo 支持两种把 iPhone sample 送到 Mac 的方式：

- `LAN`：iPhone 主动连到 Mac 的 `host:port`
- `USB`：iPhone 作为 listener，Mac 通过 `iproxy` 把本地端口转发到设备端口后主动拉流

如果只是第一次部署和调试，USB 仍然更稳；如果是日常跑 demo，LAN 和 USB 都可以。

## Demo 功能

### iPhone Demo

- 启动 / 停止 `GazeProvider`
- 展示 provider state
- 展示最新 sample 的 confidence、face distance、gaze origin、gaze dir
- `LAN` 模式下可填写 host IP + port，主动推送 sample
- `USB` 模式下在设备本地监听 `9100` 端口，等待 Mac 侧通过 USB bridge 拉流

### macOS Host

- 监听 `9000` 端口接收 iPhone sample
- 可启动 `iproxy`，把 `localhost:9101` 转发到 iPhone `9100`
- 在屏幕最上层渲染半透明 beam overlay
- overlay 不抢焦点，鼠标事件直接穿透
- 9 点校准
- 自动保存上一次成功的校准参数，并在下次启动时恢复

### Windows Host

- 监听 `9000` 端口接收 iPhone LAN sample
- 在屏幕最上层渲染半透明 beam overlay
- overlay 不抢焦点，鼠标事件直接穿透
- 60 Hz beam 动画，包含 glow、lead circle 和 trail transition
- 当前使用和 macOS fallback 一致的 `lookAtPointFM` 启发式映射
- 周期性输出 confidence、face distance 和屏幕点诊断

## 端到端校准步骤

1. 先启动 `GazeBeamHost`
2. 选择连接方式：
   - `LAN`：记下 host 窗口里显示的本机 IP，例如 `192.168.x.x:9000`，在 iPhone `GazeDemoApp` 里填入同样的 host 和 port
   - `USB`：用数据线连接 iPhone 和 Mac，在 Mac 上安装 `iproxy`，然后点击 host 窗口里的 `Start USB Bridge`，iPhone 端切到 `USB` 模式
3. iPhone 开始 tracking，并开启 stream
4. 在 Mac 端点击 `Start Calibration`
5. 依次盯住屏幕上出现的 9 个校准点，等待每个点自动采样完成
6. 状态显示 `calibration complete` 后，host 会自动保存本次校准

如果要重新做校准，点击 `Clear Calibration` 后再重新开始。

## 常见问题

- 如果 `Start Tracking` 报错 `ARFaceTracking not supported`，说明设备不支持
- 如果 app 能启动但没有 sample，多半是没授权相机，或前摄没有看到人脸
- 如果 `LAN` 流发不出去，先确认 iPhone 和 Mac 在同一网段
- 如果 `USB` 一直连不上，先确认 iPhone 已用线连到 Mac，并安装了 `iproxy`：

```bash
brew install libimobiledevice
```

- 如果 host 没有响应校准，先看 `Log` 区域里是否已经收到 `first streamed sample received`
