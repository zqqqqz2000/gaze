# Wire Protocol v1

## 目标

- iPhone 作为 provider 推送 gaze primitives
- host 发送控制消息，不传视频流
- v1 采用单连接、长度前缀 envelope

## Envelope

每个 frame 的头部固定为 16 字节：

```text
magic[4]     = "GZEP"
version_u16  = 1
channel_u8   = 1(control) / 2(data)
kind_u8      = message kind
length_u32   = payload bytes
reserved_u32 = 0
payload[length]
```

## Control Messages

control payload 使用 UTF-8 JSON。

支持的消息：

- `hello`
- `pair`
- `start_stream`
- `stop_stream`
- `begin_calibration`
- `show_target`
- `end_calibration`
- `load_calibration`
- `request_status`

## Data Messages

### kind = 1: ProviderSample

固定长度二进制布局，与 `gaze_provider_sample_t` 一一对应，所有数值按 little-endian 写入。

### kind = 2: HealthSample

预留。

### kind = 3: CalibrationAck

JSON payload。

## Calibration Blob

`gaze_calibration_t` 的持久化由 core SDK 负责，不走上面的 message envelope。

- magic: `GZCB`
- version: `1`
- encoding: little-endian
- payload: `gaze_calibration_t` 的显式字段序列化，不依赖编译器 struct layout
