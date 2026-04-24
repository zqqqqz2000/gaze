from __future__ import annotations

from dataclasses import dataclass
import struct
from typing import Optional

FLOAT_COUNT = 30
SAMPLE_PAYLOAD_LENGTH = 8 + 4 + FLOAT_COUNT * 4
WIRE_MAGIC = b"GZEP"
WIRE_VERSION = 1
WIRE_HEADER_LENGTH = 16
CHANNEL_CONTROL = 1
CHANNEL_DATA = 2
DATA_KIND_PROVIDER_SAMPLE = 1


class GazeHostError(ValueError):
    pass


@dataclass(frozen=True)
class ProviderSample:
    timestamp_ns: int
    tracking_flags: int
    gaze_origin_p_m: tuple[float, float, float]
    gaze_dir_p: tuple[float, float, float]
    left_eye_origin_p_m: tuple[float, float, float]
    left_eye_dir_p: tuple[float, float, float]
    right_eye_origin_p_m: tuple[float, float, float]
    right_eye_dir_p: tuple[float, float, float]
    head_rot_p_f_q: tuple[float, float, float, float]
    head_pos_p_m: tuple[float, float, float]
    look_at_point_f_m: tuple[float, float, float]
    confidence: float
    face_distance_m: float


@dataclass(frozen=True)
class WireEnvelope:
    channel: int
    kind: int
    payload: bytes


def encode_sample(sample: ProviderSample) -> bytes:
    floats = (
        *sample.gaze_origin_p_m,
        *sample.gaze_dir_p,
        *sample.left_eye_origin_p_m,
        *sample.left_eye_dir_p,
        *sample.right_eye_origin_p_m,
        *sample.right_eye_dir_p,
        *sample.head_rot_p_f_q,
        *sample.head_pos_p_m,
        *sample.look_at_point_f_m,
        sample.confidence,
        sample.face_distance_m,
    )
    if len(floats) != FLOAT_COUNT:
        raise GazeHostError(f"expected {FLOAT_COUNT} floats, got {len(floats)}")
    return struct.pack("<QI30f", sample.timestamp_ns, sample.tracking_flags, *floats)


def decode_sample(data: bytes) -> ProviderSample:
    if len(data) != SAMPLE_PAYLOAD_LENGTH:
        raise GazeHostError(f"bad provider sample length: expected {SAMPLE_PAYLOAD_LENGTH}, got {len(data)}")
    unpacked = struct.unpack("<QI30f", data)
    timestamp_ns = unpacked[0]
    tracking_flags = unpacked[1]
    floats = unpacked[2:]
    return ProviderSample(
        timestamp_ns=timestamp_ns,
        tracking_flags=tracking_flags,
        gaze_origin_p_m=_tuple3(floats, 0),
        gaze_dir_p=_tuple3(floats, 3),
        left_eye_origin_p_m=_tuple3(floats, 6),
        left_eye_dir_p=_tuple3(floats, 9),
        right_eye_origin_p_m=_tuple3(floats, 12),
        right_eye_dir_p=_tuple3(floats, 15),
        head_rot_p_f_q=_tuple4(floats, 18),
        head_pos_p_m=_tuple3(floats, 22),
        look_at_point_f_m=_tuple3(floats, 25),
        confidence=floats[28],
        face_distance_m=floats[29],
    )


def encode_envelope(envelope: WireEnvelope) -> bytes:
    return (
        WIRE_MAGIC
        + struct.pack("<HBBII", WIRE_VERSION, envelope.channel, envelope.kind, len(envelope.payload), 0)
        + envelope.payload
    )


def decode_envelope(data: bytes) -> WireEnvelope:
    if len(data) < WIRE_HEADER_LENGTH:
        raise GazeHostError("frame too short")
    if data[:4] != WIRE_MAGIC:
        raise GazeHostError("bad magic")
    version, channel, kind, payload_length, _reserved = struct.unpack("<HBBII", data[4:WIRE_HEADER_LENGTH])
    if version != WIRE_VERSION:
        raise GazeHostError(f"unsupported version: {version}")
    if len(data) != WIRE_HEADER_LENGTH + payload_length:
        raise GazeHostError("bad frame length")
    return WireEnvelope(channel=channel, kind=kind, payload=data[WIRE_HEADER_LENGTH:])


class WireEnvelopeStreamDecoder:
    def __init__(self) -> None:
        self._buffer = bytearray()

    @property
    def buffered_bytes(self) -> int:
        return len(self._buffer)

    def append(self, data: bytes) -> None:
        self._buffer.extend(data)

    def next_envelope(self) -> Optional[WireEnvelope]:
        if len(self._buffer) < WIRE_HEADER_LENGTH:
            return None
        if bytes(self._buffer[:4]) != WIRE_MAGIC:
            raise GazeHostError("bad magic")
        version = struct.unpack("<H", self._buffer[4:6])[0]
        if version != WIRE_VERSION:
            raise GazeHostError(f"unsupported version: {version}")
        payload_length = struct.unpack("<I", self._buffer[8:12])[0]
        frame_length = WIRE_HEADER_LENGTH + payload_length
        if len(self._buffer) < frame_length:
            return None
        envelope = WireEnvelope(
            channel=self._buffer[6],
            kind=self._buffer[7],
            payload=bytes(self._buffer[WIRE_HEADER_LENGTH:frame_length]),
        )
        del self._buffer[:frame_length]
        return envelope


def _tuple3(values: tuple[float, ...], offset: int) -> tuple[float, float, float]:
    return (values[offset], values[offset + 1], values[offset + 2])


def _tuple4(values: tuple[float, ...], offset: int) -> tuple[float, float, float, float]:
    return (values[offset], values[offset + 1], values[offset + 2], values[offset + 3])
