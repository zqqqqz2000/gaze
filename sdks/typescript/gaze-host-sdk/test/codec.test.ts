import assert from "node:assert/strict";
import test from "node:test";
import {
  CHANNEL_DATA,
  DATA_KIND_PROVIDER_SAMPLE,
  SAMPLE_PAYLOAD_LENGTH,
  WireEnvelopeStreamDecoder,
  decodeEnvelope,
  decodeSample,
  encodeEnvelope,
  encodeSample,
  type ProviderSample,
} from "../src/index.js";

test("sample round trip preserves fields", () => {
  const sample = makeSample();
  const encoded = encodeSample(sample);
  assert.equal(encoded.byteLength, SAMPLE_PAYLOAD_LENGTH);
  const decoded = decodeSample(encoded);
  assert.equal(decoded.timestampNs, sample.timestampNs);
  assert.equal(decoded.trackingFlags, sample.trackingFlags);
  assert.equal(decoded.confidence.toFixed(6), sample.confidence.toFixed(6));
  assert.equal(decoded.faceDistanceM.toFixed(6), sample.faceDistanceM.toFixed(6));
});

test("envelope round trip preserves payload", () => {
  const envelope = {
    channel: CHANNEL_DATA,
    kind: DATA_KIND_PROVIDER_SAMPLE,
    payload: encodeSample(makeSample()),
  };
  assert.deepEqual(decodeEnvelope(encodeEnvelope(envelope)), envelope);
});

test("stream decoder consumes split and multiple frames", () => {
  const frameA = encodeEnvelope({ channel: CHANNEL_DATA, kind: DATA_KIND_PROVIDER_SAMPLE, payload: new Uint8Array([1, 2, 3]) });
  const frameB = encodeEnvelope({ channel: CHANNEL_DATA, kind: DATA_KIND_PROVIDER_SAMPLE, payload: new Uint8Array([4, 5]) });
  const decoder = new WireEnvelopeStreamDecoder();
  decoder.append(frameA.slice(0, frameA.byteLength - 2));
  assert.equal(decoder.nextEnvelope(), null);
  decoder.append(frameA.slice(frameA.byteLength - 2));
  decoder.append(frameB);
  assert.deepEqual(decoder.nextEnvelope()?.payload, new Uint8Array([1, 2, 3]));
  assert.deepEqual(decoder.nextEnvelope()?.payload, new Uint8Array([4, 5]));
  assert.equal(decoder.nextEnvelope(), null);
});

function makeSample(): ProviderSample {
  return {
    timestampNs: 42n,
    trackingFlags: 1,
    gazeOriginPM: [0.1, 0.2, 0.3],
    gazeDirP: [0.0, 0.1, 1.0],
    leftEyeOriginPM: [-0.02, 0.0, 0.3],
    leftEyeDirP: [0.0, 0.0, 1.0],
    rightEyeOriginPM: [0.02, 0.0, 0.3],
    rightEyeDirP: [0.0, 0.0, 1.0],
    headRotPFQ: [0.0, 0.0, 0.0, 1.0],
    headPosPM: [0.0, 0.0, 0.6],
    lookAtPointFM: [0.01, -0.02, 1.0],
    confidence: 0.95,
    faceDistanceM: 0.6,
  };
}
