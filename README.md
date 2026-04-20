# Gaze SDK

基于 iPhone 的眼动追踪 SDK v1 实现。

仓库按三层拆分：

- `core/`: 跨平台 C++17 核心库，提供几何解算、校准会话、C ABI
- `ios/` / `Sources/`: iPhone Provider Swift Package，基于 `ARKit` 输出 gaze primitives
- `protocol/`: wire protocol 与坐标系约定
- `tests/`: 核心几何与校准流程测试

## 当前实现范围

已实现：

- `gaze_provider_sample_t` / `gaze_calibration_t` / `DisplayPose` 等公共结构
- `gaze_solve_point()` 屏幕求交与 residual 修正
- `gaze_cal_*()` full calibration API
- `gaze_refit_pose()` quick refit API
- iPhone `GazeProvider` Swift Package
- 二进制 sample codec 与长度前缀 envelope
- C++ 单测与 Swift 协议层测试

当前未做：

- 多显示器 profile 管理
- 真正的 host UI
- protobuf / flatbuffers
- 持久化 blob 的多版本迁移工具

## 目录

```text
core/
  include/gaze/gaze_sdk.h
  src/gaze_sdk.cpp
docs/
  architecture.md
protocol/
  wire_protocol.md
Sources/
  GazeProtocolKit/
  GazeProviderKit/
Tests/
  GazeProtocolKitTests/
tests/
  core_tests.cpp
```

## 构建

当前环境没有 `cmake`，仓库提供了基于 `clang++` 的 `Makefile`。

```bash
make test
swift build
```

如果本机是完整 Xcode / XCTest 环境，也可以额外执行：

```bash
swift test
```

## 设计原则

- iPhone 只提供 gaze primitives，不直接输出屏幕坐标
- host/core 负责 `DisplayPose + UserBias + residual` 解算
- `DisplayPose` 是屏幕平面完整位姿，不是一个平移向量
- v1 先做 `ARKit-only`
