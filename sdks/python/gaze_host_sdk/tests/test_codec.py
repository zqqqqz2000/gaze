import unittest

from gaze_host_sdk import (
    CHANNEL_DATA,
    DATA_KIND_PROVIDER_SAMPLE,
    SAMPLE_PAYLOAD_LENGTH,
    ProviderSample,
    WireEnvelope,
    WireEnvelopeStreamDecoder,
    decode_envelope,
    decode_sample,
    encode_envelope,
    encode_sample,
)


class CodecTests(unittest.TestCase):
    def test_sample_round_trip_preserves_fields(self) -> None:
        sample = make_sample()
        encoded = encode_sample(sample)
        self.assertEqual(len(encoded), SAMPLE_PAYLOAD_LENGTH)
        decoded = decode_sample(encoded)
        self.assertEqual(decoded.timestamp_ns, sample.timestamp_ns)
        self.assertEqual(decoded.tracking_flags, sample.tracking_flags)
        self.assertAlmostEqual(decoded.confidence, sample.confidence, places=6)
        self.assertAlmostEqual(decoded.face_distance_m, sample.face_distance_m, places=6)

    def test_envelope_round_trip_preserves_payload(self) -> None:
        envelope = WireEnvelope(CHANNEL_DATA, DATA_KIND_PROVIDER_SAMPLE, encode_sample(make_sample()))
        self.assertEqual(decode_envelope(encode_envelope(envelope)), envelope)

    def test_stream_decoder_consumes_split_and_multiple_frames(self) -> None:
        frame_a = encode_envelope(WireEnvelope(CHANNEL_DATA, DATA_KIND_PROVIDER_SAMPLE, b"abc"))
        frame_b = encode_envelope(WireEnvelope(CHANNEL_DATA, DATA_KIND_PROVIDER_SAMPLE, b"de"))
        decoder = WireEnvelopeStreamDecoder()
        decoder.append(frame_a[:-2])
        self.assertIsNone(decoder.next_envelope())
        decoder.append(frame_a[-2:] + frame_b)
        self.assertEqual(decoder.next_envelope().payload, b"abc")
        self.assertEqual(decoder.next_envelope().payload, b"de")
        self.assertIsNone(decoder.next_envelope())


def make_sample() -> ProviderSample:
    return ProviderSample(
        timestamp_ns=42,
        tracking_flags=1,
        gaze_origin_p_m=(0.1, 0.2, 0.3),
        gaze_dir_p=(0.0, 0.1, 1.0),
        left_eye_origin_p_m=(-0.02, 0.0, 0.3),
        left_eye_dir_p=(0.0, 0.0, 1.0),
        right_eye_origin_p_m=(0.02, 0.0, 0.3),
        right_eye_dir_p=(0.0, 0.0, 1.0),
        head_rot_p_f_q=(0.0, 0.0, 0.0, 1.0),
        head_pos_p_m=(0.0, 0.0, 0.6),
        look_at_point_f_m=(0.01, -0.02, 1.0),
        confidence=0.95,
        face_distance_m=0.6,
    )


if __name__ == "__main__":
    unittest.main()
