export const FLOAT_COUNT = 30;
export const SAMPLE_PAYLOAD_LENGTH = 8 + 4 + FLOAT_COUNT * 4;
export const WIRE_MAGIC = "GZEP";
export const WIRE_VERSION = 1;
export const WIRE_HEADER_LENGTH = 16;
export const CHANNEL_CONTROL = 1;
export const CHANNEL_DATA = 2;
export const DATA_KIND_PROVIDER_SAMPLE = 1;

export interface ProviderSample {
  timestampNs: bigint;
  trackingFlags: number;
  gazeOriginPM: readonly [number, number, number];
  gazeDirP: readonly [number, number, number];
  leftEyeOriginPM: readonly [number, number, number];
  leftEyeDirP: readonly [number, number, number];
  rightEyeOriginPM: readonly [number, number, number];
  rightEyeDirP: readonly [number, number, number];
  headRotPFQ: readonly [number, number, number, number];
  headPosPM: readonly [number, number, number];
  lookAtPointFM: readonly [number, number, number];
  confidence: number;
  faceDistanceM: number;
}

export interface WireEnvelope {
  channel: number;
  kind: number;
  payload: Uint8Array;
}

export class GazeHostError extends Error {}

export function encodeSample(sample: ProviderSample): Uint8Array {
  const buffer = new ArrayBuffer(SAMPLE_PAYLOAD_LENGTH);
  const view = new DataView(buffer);
  let offset = 0;
  view.setBigUint64(offset, sample.timestampNs, true);
  offset += 8;
  view.setUint32(offset, sample.trackingFlags, true);
  offset += 4;
  for (const value of sampleFloats(sample)) {
    view.setFloat32(offset, value, true);
    offset += 4;
  }
  return new Uint8Array(buffer);
}

export function decodeSample(bytes: Uint8Array): ProviderSample {
  if (bytes.byteLength !== SAMPLE_PAYLOAD_LENGTH) {
    throw new GazeHostError(`bad provider sample length: expected ${SAMPLE_PAYLOAD_LENGTH}, got ${bytes.byteLength}`);
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let offset = 0;
  const timestampNs = view.getBigUint64(offset, true);
  offset += 8;
  const trackingFlags = view.getUint32(offset, true);
  offset += 4;
  const floats: number[] = [];
  for (let i = 0; i < FLOAT_COUNT; i += 1) {
    floats.push(view.getFloat32(offset, true));
    offset += 4;
  }
  return {
    timestampNs,
    trackingFlags,
    gazeOriginPM: tuple3(floats, 0),
    gazeDirP: tuple3(floats, 3),
    leftEyeOriginPM: tuple3(floats, 6),
    leftEyeDirP: tuple3(floats, 9),
    rightEyeOriginPM: tuple3(floats, 12),
    rightEyeDirP: tuple3(floats, 15),
    headRotPFQ: tuple4(floats, 18),
    headPosPM: tuple3(floats, 22),
    lookAtPointFM: tuple3(floats, 25),
    confidence: floats[28],
    faceDistanceM: floats[29],
  };
}

export function encodeEnvelope(envelope: WireEnvelope): Uint8Array {
  const buffer = new Uint8Array(WIRE_HEADER_LENGTH + envelope.payload.byteLength);
  buffer.set(new TextEncoder().encode(WIRE_MAGIC), 0);
  const view = new DataView(buffer.buffer);
  view.setUint16(4, WIRE_VERSION, true);
  view.setUint8(6, envelope.channel);
  view.setUint8(7, envelope.kind);
  view.setUint32(8, envelope.payload.byteLength, true);
  view.setUint32(12, 0, true);
  buffer.set(envelope.payload, WIRE_HEADER_LENGTH);
  return buffer;
}

export function decodeEnvelope(bytes: Uint8Array): WireEnvelope {
  if (bytes.byteLength < WIRE_HEADER_LENGTH) {
    throw new GazeHostError("frame too short");
  }
  const magic = new TextDecoder().decode(bytes.subarray(0, 4));
  if (magic !== WIRE_MAGIC) {
    throw new GazeHostError("bad magic");
  }
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const version = view.getUint16(4, true);
  if (version !== WIRE_VERSION) {
    throw new GazeHostError(`unsupported version: ${version}`);
  }
  const payloadLength = view.getUint32(8, true);
  if (bytes.byteLength !== WIRE_HEADER_LENGTH + payloadLength) {
    throw new GazeHostError("bad frame length");
  }
  return {
    channel: view.getUint8(6),
    kind: view.getUint8(7),
    payload: bytes.slice(WIRE_HEADER_LENGTH),
  };
}

export class WireEnvelopeStreamDecoder {
  private buffer = new Uint8Array(0);

  get bufferedBytes(): number {
    return this.buffer.byteLength;
  }

  append(bytes: Uint8Array): void {
    const merged = new Uint8Array(this.buffer.byteLength + bytes.byteLength);
    merged.set(this.buffer, 0);
    merged.set(bytes, this.buffer.byteLength);
    this.buffer = merged;
  }

  nextEnvelope(): WireEnvelope | null {
    if (this.buffer.byteLength < WIRE_HEADER_LENGTH) {
      return null;
    }
    const magic = new TextDecoder().decode(this.buffer.subarray(0, 4));
    if (magic !== WIRE_MAGIC) {
      throw new GazeHostError("bad magic");
    }
    const view = new DataView(this.buffer.buffer, this.buffer.byteOffset, this.buffer.byteLength);
    const version = view.getUint16(4, true);
    if (version !== WIRE_VERSION) {
      throw new GazeHostError(`unsupported version: ${version}`);
    }
    const payloadLength = view.getUint32(8, true);
    const frameLength = WIRE_HEADER_LENGTH + payloadLength;
    if (this.buffer.byteLength < frameLength) {
      return null;
    }
    const envelope = {
      channel: view.getUint8(6),
      kind: view.getUint8(7),
      payload: this.buffer.slice(WIRE_HEADER_LENGTH, frameLength),
    };
    this.buffer = this.buffer.slice(frameLength);
    return envelope;
  }
}

function sampleFloats(sample: ProviderSample): number[] {
  return [
    ...sample.gazeOriginPM,
    ...sample.gazeDirP,
    ...sample.leftEyeOriginPM,
    ...sample.leftEyeDirP,
    ...sample.rightEyeOriginPM,
    ...sample.rightEyeDirP,
    ...sample.headRotPFQ,
    ...sample.headPosPM,
    ...sample.lookAtPointFM,
    sample.confidence,
    sample.faceDistanceM,
  ];
}

function tuple3(values: readonly number[], offset: number): [number, number, number] {
  return [values[offset], values[offset + 1], values[offset + 2]];
}

function tuple4(values: readonly number[], offset: number): [number, number, number, number] {
  return [values[offset], values[offset + 1], values[offset + 2], values[offset + 3]];
}
