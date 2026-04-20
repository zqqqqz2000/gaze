# Gaze SDK 架构

## 分层

### 1. iPhone Provider

- 基于 `ARKit` face tracking
- 输出 gaze primitives
- 可选网络发送给 host
- 接收校准控制消息

### 2. Cross-platform Core

- C++17 单一核心
- C ABI 暴露给 macOS / Windows / Linux
- 实现 `DisplayPose`、校准求解、quick refit、runtime solve

### 3. Host Layer

- 发现并连接 iPhone
- 展示校准目标点
- 调用 core 求 `gaze_calibration_t`
- 将 normalized point 转换为像素坐标

## 坐标系

### Screen frame

- 原点：屏幕中心
- `+X`：屏幕向右
- `+Y`：屏幕向上
- `+Z`：从屏幕指向用户

### Provider frame

- 由 provider 自己定义
- 所有样本字段都必须在同一 provider frame 下输出
- `T_provider_from_screen` 负责桥接 screen frame 与 provider frame

## 校准模型

`gaze_calibration_t` 由三部分组成：

- `DisplayPose`
- `UserBias`
- `ResidualMap`

当前 v1 求解器实现：

- Full calibration：优化 `DisplayPose + yaw/pitch bias`
- Quick refit：仅优化 `DisplayPose` 小扰动
- Residual：保留 2D 二次项接口，默认可为零
