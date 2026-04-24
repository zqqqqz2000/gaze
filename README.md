<a id="english"></a>

# 👀 Gaze SDK

**Language:** [English](#english) | [中文](#中文)

Gaze SDK turns an iPhone with ARKit face tracking into a host-controlled gaze input and maps it onto the screen. The iPhone streams gaze primitives, while the host calibrates them against the active display and resolves live gaze points for overlays, interaction, diagnostics, or downstream applications.

## ⚡ Quickstart

Add the package with Swift Package Manager:

```swift
.package(url: "https://github.com/zqqqqz2000/gaze.git", branch: "main")
```

Capture iPhone gaze samples with `GazeProviderKit`:

```swift
import GazeProviderKit

let provider = GazeProvider()
provider.onSample = { sample in
    // Send sample to a host, record it, or feed it into your own pipeline.
    print(sample.confidence, sample.gazeOriginPM, sample.gazeDirP)
}

try provider.start()
```

Calibrate and solve screen points with `GazeCoreKit`:

```swift
import GazeCoreKit
import GazeProtocolKit

let display = GazeDisplayDescriptor(
    screenWidthMM: 345,
    screenHeightMM: 215,
    widthPixels: 3024,
    heightPixels: 1964
)

let session = GazeCalibrationSession(display: display)!
try session.pushTarget(u: 0.5, v: 0.5, targetID: 0)
try session.pushSample(sample, targetID: 0)

let calibration = try session.solve()
let point = try calibration.solvePoint(sample: sample, display: display)
print(point.xPixels, point.yPixels, point.insideScreen)
```

Encode samples for a custom stream with `GazeProtocolKit`:

```swift
import GazeProtocolKit

let payload = BinarySampleCodec.encode(sample)
let envelope = WireEnvelope(
    channel: .data,
    kind: DataMessageKind.providerSample.rawValue,
    payload: payload
)

let bytes = envelope.encode()
```

For a complete app flow, run `GazeBeamHost` on macOS and `GazeDemoApp` on a Face ID capable iPhone, then connect over LAN or USB and start host calibration.

Use host-side protocol SDKs outside Swift:

```bash
cargo add --path sdks/rust/gaze-host-sdk
python3 -m pip install -e sdks/python/gaze_host_sdk
npm install ./sdks/typescript/gaze-host-sdk
```

## ✨ Features

### 📱 iPhone Gaze Provider

- Uses `ARKit` face tracking to emit gaze primitives instead of screen-space guesses.
- Streams gaze origin, gaze direction, eye rays, head pose, confidence, and face distance.
- Supports LAN push mode from iPhone to host.
- Supports USB mode where the iPhone listens locally and the Mac connects through `iproxy`.
- Keeps provider logic separate from host calibration, so the same stream can feed different host applications.

### 🖥️ macOS Host Demo

- Receives live iPhone samples over TCP.
- Starts and supervises an optional USB bridge through `iproxy`.
- Runs host-side 9-point calibration against the active display.
- Persists successful calibration and restores it on next launch.
- Renders a transparent gaze beam overlay above all windows.
- Keeps the overlay click-through and non-focus-stealing.
- Supports bare-eye and glasses calibration states.
- Includes runtime diagnostics for confidence, head pose drift, clamping, and solve failures.

### 🧠 Cross-Platform Core

- C++17 core with a stable C ABI in `core/include/gaze/gaze_sdk.h`.
- Solves screen-space gaze points from provider samples, display descriptors, and calibration blobs.
- Provides full calibration, glasses calibration, quick pose refit, residual correction, and calibration serialization.
- Keeps the math layer independent from SwiftUI, AppKit, ARKit, and networking.
- Includes C++ tests for the geometry and calibration pipeline.

### 📦 Swift Packages

- `GazeProtocolKit`: wire protocol, envelope stream decoder, binary sample codec, and payload models.
- `GazeProviderKit`: iPhone-side provider abstractions.
- `GazeCoreKit`: Swift wrapper around the C ABI and calibration/runtime solve APIs.
- Swift Package Manager ready through the repository-level `Package.swift`.

### 🧩 Host SDKs

- Rust host SDK for decoding provider samples and wire envelopes.
- Python host SDK for receiving/decoding custom gaze streams.
- TypeScript host SDK for Node-based host tools and web service bridges.
- All host SDKs include unit tests for sample codec and stream decoder behavior.

### 🔌 Wire Protocol

- Compact binary sample codec for high-rate gaze streams.
- Length-prefixed envelope protocol with channel and message kind fields.
- Incremental stream decoder for TCP chunks and multi-frame buffers.
- Protocol docs live in [`protocol/wire_protocol.md`](protocol/wire_protocol.md).

### 🧪 Testing & Validation

- `make test` validates the C++ core.
- `swift test` validates Swift protocol and core wrapper behavior.
- `xcodebuild` can build the iPhone and macOS demo targets.
- The host demo contains logging and diagnostics for live calibration sessions.

## 🕹️ Demo Flow

1. Launch `GazeBeamHost` on macOS.
2. Launch `GazeDemoApp` on a real iPhone that supports `ARFaceTrackingConfiguration`.
3. Pick a connection mode:
   - LAN: enter the Mac host and port shown by `GazeBeamHost`.
   - USB: install `iproxy` with `brew install libimobiledevice`, connect the iPhone by cable, and click `Start USB Bridge`.
4. Start tracking and streaming on the iPhone.
5. Click `Start Calibration` on the Mac.
6. Look at each calibration target until collection advances automatically.
7. Use the live gaze overlay after `calibration complete`.

## 📁 Repository Layout

```text
core/
  include/gaze/gaze_sdk.h       # Public C ABI
  src/gaze_sdk.cpp              # C++17 core implementation
demo/
  GazeDemoApp/                  # iPhone provider demo
  GazeBeamHost/                 # macOS host + overlay demo
docs/
  architecture.md               # Architecture notes
protocol/
  wire_protocol.md              # Wire protocol notes
Sources/
  GazeCoreKit/                  # Swift wrapper for core
  GazeProviderKit/              # Provider-side Swift APIs
  GazeProtocolKit/              # Protocol and codec APIs
tests/
  core_tests.cpp
  GazeProtocolKitTests/
```

## 📦 Package Manager

### ✅ Swift Package Manager

The repository contains `Package.swift` and exposes `GazeProtocolKit`, `GazeProviderKit`, and `GazeCoreKit`.

Use it from another Swift package:

```swift
.package(url: "https://github.com/zqqqqz2000/gaze.git", branch: "main")
```

Then depend on the needed product:

```swift
.product(name: "GazeCoreKit", package: "gaze")
```

### ✅ Cargo

The Rust host SDK can be used as a local path dependency:

```toml
[dependencies]
gaze-host-sdk = { path = "sdks/rust/gaze-host-sdk" }
```

### ✅ pip

The Python host SDK can be installed from the repository checkout:

```bash
python3 -m pip install -e sdks/python/gaze_host_sdk
```

### ✅ npm

The TypeScript host SDK can be installed from the repository checkout:

```bash
npm install ./sdks/typescript/gaze-host-sdk
```

## 🔧 Technical Details

### Architecture

Gaze SDK is split into three layers:

- Provider: iPhone ARKit capture and sample streaming.
- Core: display pose, tangent-affine correction, calibration, refit, residual correction, and runtime solve.
- Host: connection management, calibration UI, overlay rendering, diagnostics, and persistence.

### Coordinate Model

- Screen frame origin is the screen center.
- Screen `+X` points right.
- Screen `+Y` points up.
- Screen `+Z` points from the screen toward the user.
- Provider frame is defined by the provider.
- `T_provider_from_screen` bridges the screen frame into provider coordinates.

### Calibration Model

`gaze_calibration_t` stores:

- Screen pose as `T_provider_from_screen`.
- Bare-eye tangent-affine correction.
- Optional glasses tangent-affine correction.
- Residual polynomial coefficients.
- Quality metrics and sample counts.

The runtime solve path applies the active tangent-affine correction, intersects the corrected ray with the calibrated screen plane, applies residual correction, and returns normalized and pixel-space coordinates.

---

<a id="中文"></a>

# 👀 Gaze SDK 中文

**语言:** [English](#english) | [中文](#中文)

Gaze SDK 将支持 ARKit 人脸追踪的 iPhone 变成一条 host 可控的眼动输入，并映射到屏幕。iPhone 只输出 gaze primitives，Mac/host 负责屏幕校准、实时解算和 overlay/交互/诊断等上层能力。

## ⚡ 快速开始

通过 Swift Package Manager 添加依赖：

```swift
.package(url: "https://github.com/zqqqqz2000/gaze.git", branch: "main")
```

用 `GazeProviderKit` 在 iPhone 侧采集 gaze sample：

```swift
import GazeProviderKit

let provider = GazeProvider()
provider.onSample = { sample in
    // 可以发送给 host、落盘，或接入你自己的实时处理链路。
    print(sample.confidence, sample.gazeOriginPM, sample.gazeDirP)
}

try provider.start()
```

用 `GazeCoreKit` 在 host 侧做校准和屏幕点解算：

```swift
import GazeCoreKit
import GazeProtocolKit

let display = GazeDisplayDescriptor(
    screenWidthMM: 345,
    screenHeightMM: 215,
    widthPixels: 3024,
    heightPixels: 1964
)

let session = GazeCalibrationSession(display: display)!
try session.pushTarget(u: 0.5, v: 0.5, targetID: 0)
try session.pushSample(sample, targetID: 0)

let calibration = try session.solve()
let point = try calibration.solvePoint(sample: sample, display: display)
print(point.xPixels, point.yPixels, point.insideScreen)
```

用 `GazeProtocolKit` 编码 sample，接入自定义网络流：

```swift
import GazeProtocolKit

let payload = BinarySampleCodec.encode(sample)
let envelope = WireEnvelope(
    channel: .data,
    kind: DataMessageKind.providerSample.rawValue,
    payload: payload
)

let bytes = envelope.encode()
```

如果需要完整 app 流程，可以在 macOS 上运行 `GazeBeamHost`，在支持 Face ID/ARKit Face Tracking 的 iPhone 真机上运行 `GazeDemoApp`，通过 LAN 或 USB 连接后开始 host 侧校准。

在 Swift 之外使用 host 侧协议 SDK：

```bash
cargo add --path sdks/rust/gaze-host-sdk
python3 -m pip install -e sdks/python/gaze_host_sdk
npm install ./sdks/typescript/gaze-host-sdk
```

## ✨ 能力特性

### 📱 iPhone Gaze Provider

- 基于 `ARKit` face tracking 输出 gaze primitives，而不是直接猜屏幕坐标。
- 输出 gaze origin、gaze direction、左右眼射线、头部位姿、confidence、face distance。
- 支持 iPhone 主动连接 host 的 LAN 推流模式。
- 支持 USB 模式：iPhone 本地监听，Mac 通过 `iproxy` 连接设备端口。
- provider 与 host 校准解耦，同一条 sample 流可以接入不同 host 应用。

### 🖥️ macOS Host Demo

- 通过 TCP 接收 iPhone 实时 sample。
- 可启动并管理 `iproxy` USB bridge。
- 在 host 侧基于当前屏幕执行 9 点校准。
- 自动保存成功校准结果，并在下次启动恢复。
- 在所有窗口上层渲染透明 gaze beam overlay。
- overlay 不抢焦点，鼠标事件穿透。
- 支持裸眼和眼镜两套校准状态。
- 提供 confidence、头部漂移、边界 clamp、解算失败等运行时诊断。

### 🧠 跨平台核心

- C++17 核心库，公开稳定 C ABI：`core/include/gaze/gaze_sdk.h`。
- 基于 provider sample、display descriptor、calibration blob 解算屏幕 gaze point。
- 支持完整校准、眼镜校准、quick pose refit、residual 修正、校准序列化。
- 数学核心不依赖 SwiftUI、AppKit、ARKit 或网络层。
- 包含 C++ 单测覆盖几何和校准流程。

### 📦 Swift Package

- `GazeProtocolKit`：wire protocol、流式 envelope decoder、二进制 sample codec、payload model。
- `GazeProviderKit`：iPhone provider 侧抽象。
- `GazeCoreKit`：C ABI 的 Swift 封装，提供校准与实时解算 API。
- 仓库根目录已提供 `Package.swift`，可直接用 Swift Package Manager 接入。

### 🧩 Host SDK

- Rust host SDK：解码 provider sample 和 wire envelope。
- Python host SDK：用于接收/解码自定义 gaze stream。
- TypeScript host SDK：用于 Node host 工具和 Web service bridge。
- 所有 host SDK 都包含 sample codec 和 stream decoder 单元测试。

### 🔌 Wire Protocol

- 面向高频 gaze 流的紧凑二进制 sample codec。
- 带 channel 和 message kind 的长度前缀 envelope。
- 支持 TCP 分片和单 buffer 多帧的增量 stream decoder。
- 协议说明见 [`protocol/wire_protocol.md`](protocol/wire_protocol.md)。

### 🧪 测试与验证

- `make test` 验证 C++ core。
- `swift test` 验证 Swift 协议层和 core wrapper。
- `xcodebuild` 可构建 iPhone 和 macOS demo target。
- host demo 内置 live calibration 日志和诊断能力。

## 🕹️ Demo 流程

1. 在 Mac 上启动 `GazeBeamHost`。
2. 在支持 `ARFaceTrackingConfiguration` 的 iPhone 真机上启动 `GazeDemoApp`。
3. 选择连接方式：
   - LAN：在 iPhone 端填写 host 窗口显示的 Mac IP 和端口。
   - USB：用 `brew install libimobiledevice` 安装 `iproxy`，数据线连接 iPhone，点击 host 里的 `Start USB Bridge`。
4. iPhone 端开始 tracking 和 streaming。
5. Mac 端点击 `Start Calibration`。
6. 依次看向每个校准点，等待自动采样完成。
7. 状态显示 `calibration complete` 后即可使用实时 gaze overlay。

## 📁 目录结构

```text
core/
  include/gaze/gaze_sdk.h       # 公共 C ABI
  src/gaze_sdk.cpp              # C++17 核心实现
demo/
  GazeDemoApp/                  # iPhone provider demo
  GazeBeamHost/                 # macOS host + overlay demo
docs/
  architecture.md               # 架构说明
protocol/
  wire_protocol.md              # 协议说明
Sources/
  GazeCoreKit/                  # core 的 Swift 封装
  GazeProviderKit/              # provider 侧 Swift API
  GazeProtocolKit/              # 协议和 codec API
tests/
  core_tests.cpp
  GazeProtocolKitTests/
```

## 📦 包管理器

### ✅ Swift Package Manager

仓库已经提供 `Package.swift`，并暴露 `GazeProtocolKit`、`GazeProviderKit`、`GazeCoreKit`。

在其他 Swift package 中添加：

```swift
.package(url: "https://github.com/zqqqqz2000/gaze.git", branch: "main")
```

然后依赖需要的 product：

```swift
.product(name: "GazeCoreKit", package: "gaze")
```

### ✅ Cargo

Rust host SDK 可作为本地 path dependency 使用：

```toml
[dependencies]
gaze-host-sdk = { path = "sdks/rust/gaze-host-sdk" }
```

### ✅ pip

Python host SDK 可从仓库 checkout 安装：

```bash
python3 -m pip install -e sdks/python/gaze_host_sdk
```

### ✅ npm

TypeScript host SDK 可从仓库 checkout 安装：

```bash
npm install ./sdks/typescript/gaze-host-sdk
```

## 🔧 技术细节

### 架构

Gaze SDK 分三层：

- Provider：iPhone ARKit 采集和 sample 推流。
- Core：屏幕位姿、tangent-affine 修正、校准、refit、residual 修正和实时解算。
- Host：连接管理、校准 UI、overlay 渲染、诊断和持久化。

### 坐标模型

- Screen frame 原点在屏幕中心。
- Screen `+X` 指向屏幕右侧。
- Screen `+Y` 指向屏幕上方。
- Screen `+Z` 从屏幕指向用户。
- Provider frame 由 provider 定义。
- `T_provider_from_screen` 负责把 screen frame 桥接到 provider 坐标系。

### 校准模型

`gaze_calibration_t` 包含：

- 屏幕位姿 `T_provider_from_screen`。
- 裸眼 tangent-affine 修正。
- 可选眼镜 tangent-affine 修正。
- residual 多项式系数。
- 质量指标和样本数。

运行时解算会应用当前 active 的 tangent-affine 修正，将修正后的射线与校准屏幕平面求交，应用 residual 修正，并返回 normalized 与 pixel-space 坐标。
