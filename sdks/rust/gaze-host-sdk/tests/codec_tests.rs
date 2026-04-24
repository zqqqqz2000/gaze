use gaze_host_sdk::{
    decode_envelope, decode_sample, encode_envelope, encode_sample, ProviderSample, WireEnvelope,
    WireEnvelopeStreamDecoder, CHANNEL_DATA, DATA_KIND_PROVIDER_SAMPLE, SAMPLE_PAYLOAD_LENGTH,
};

#[test]
fn sample_round_trip_preserves_fields() {
    let sample = sample();
    let encoded = encode_sample(&sample);
    assert_eq!(encoded.len(), SAMPLE_PAYLOAD_LENGTH);
    assert_eq!(decode_sample(&encoded).unwrap(), sample);
}

#[test]
fn stream_decoder_consumes_split_and_multiple_frames() {
    let frame_a = encode_envelope(&WireEnvelope { channel: CHANNEL_DATA, kind: DATA_KIND_PROVIDER_SAMPLE, payload: vec![1, 2, 3] });
    let frame_b = encode_envelope(&WireEnvelope { channel: CHANNEL_DATA, kind: DATA_KIND_PROVIDER_SAMPLE, payload: vec![4, 5] });
    let split = frame_a.len() - 2;
    let mut decoder = WireEnvelopeStreamDecoder::new();
    decoder.append(&frame_a[..split]);
    assert_eq!(decoder.next_envelope().unwrap(), None);
    decoder.append(&frame_a[split..]);
    decoder.append(&frame_b);
    assert_eq!(decoder.next_envelope().unwrap().unwrap().payload, vec![1, 2, 3]);
    assert_eq!(decoder.next_envelope().unwrap().unwrap().payload, vec![4, 5]);
    assert_eq!(decoder.next_envelope().unwrap(), None);
}

#[test]
fn envelope_round_trip_preserves_payload() {
    let envelope = WireEnvelope { channel: CHANNEL_DATA, kind: DATA_KIND_PROVIDER_SAMPLE, payload: encode_sample(&sample()) };
    assert_eq!(decode_envelope(&encode_envelope(&envelope)).unwrap(), envelope);
}

fn sample() -> ProviderSample {
    ProviderSample {
        timestamp_ns: 42,
        tracking_flags: 1,
        gaze_origin_p_m: [0.1, 0.2, 0.3],
        gaze_dir_p: [0.0, 0.1, 1.0],
        left_eye_origin_p_m: [-0.02, 0.0, 0.3],
        left_eye_dir_p: [0.0, 0.0, 1.0],
        right_eye_origin_p_m: [0.02, 0.0, 0.3],
        right_eye_dir_p: [0.0, 0.0, 1.0],
        head_rot_p_f_q: [0.0, 0.0, 0.0, 1.0],
        head_pos_p_m: [0.0, 0.0, 0.6],
        look_at_point_f_m: [0.01, -0.02, 1.0],
        confidence: 0.95,
        face_distance_m: 0.6,
    }
}
