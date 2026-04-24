pub const FLOAT_COUNT: usize = 30;
pub const SAMPLE_PAYLOAD_LENGTH: usize = 8 + 4 + FLOAT_COUNT * 4;
pub const WIRE_MAGIC: &[u8; 4] = b"GZEP";
pub const WIRE_VERSION: u16 = 1;
pub const WIRE_HEADER_LENGTH: usize = 16;
pub const CHANNEL_CONTROL: u8 = 1;
pub const CHANNEL_DATA: u8 = 2;
pub const DATA_KIND_PROVIDER_SAMPLE: u8 = 1;

#[derive(Debug, Clone, PartialEq)]
pub struct ProviderSample {
    pub timestamp_ns: u64,
    pub tracking_flags: u32,
    pub gaze_origin_p_m: [f32; 3],
    pub gaze_dir_p: [f32; 3],
    pub left_eye_origin_p_m: [f32; 3],
    pub left_eye_dir_p: [f32; 3],
    pub right_eye_origin_p_m: [f32; 3],
    pub right_eye_dir_p: [f32; 3],
    pub head_rot_p_f_q: [f32; 4],
    pub head_pos_p_m: [f32; 3],
    pub look_at_point_f_m: [f32; 3],
    pub confidence: f32,
    pub face_distance_m: f32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WireEnvelope {
    pub channel: u8,
    pub kind: u8,
    pub payload: Vec<u8>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GazeHostError {
    BadPayloadLength { expected: usize, actual: usize },
    FrameTooShort,
    BadMagic,
    UnsupportedVersion(u16),
    BadLength,
}

pub type Result<T> = std::result::Result<T, GazeHostError>;

pub fn encode_sample(sample: &ProviderSample) -> Vec<u8> {
    let mut out = Vec::with_capacity(SAMPLE_PAYLOAD_LENGTH);
    out.extend_from_slice(&sample.timestamp_ns.to_le_bytes());
    out.extend_from_slice(&sample.tracking_flags.to_le_bytes());
    append_f32_array(&mut out, &sample.gaze_origin_p_m);
    append_f32_array(&mut out, &sample.gaze_dir_p);
    append_f32_array(&mut out, &sample.left_eye_origin_p_m);
    append_f32_array(&mut out, &sample.left_eye_dir_p);
    append_f32_array(&mut out, &sample.right_eye_origin_p_m);
    append_f32_array(&mut out, &sample.right_eye_dir_p);
    append_f32_array(&mut out, &sample.head_rot_p_f_q);
    append_f32_array(&mut out, &sample.head_pos_p_m);
    append_f32_array(&mut out, &sample.look_at_point_f_m);
    out.extend_from_slice(&sample.confidence.to_le_bytes());
    out.extend_from_slice(&sample.face_distance_m.to_le_bytes());
    out
}

pub fn decode_sample(bytes: &[u8]) -> Result<ProviderSample> {
    if bytes.len() != SAMPLE_PAYLOAD_LENGTH {
        return Err(GazeHostError::BadPayloadLength {
            expected: SAMPLE_PAYLOAD_LENGTH,
            actual: bytes.len(),
        });
    }
    let mut reader = ByteReader::new(bytes);
    Ok(ProviderSample {
        timestamp_ns: reader.read_u64(),
        tracking_flags: reader.read_u32(),
        gaze_origin_p_m: reader.read_f32_array::<3>(),
        gaze_dir_p: reader.read_f32_array::<3>(),
        left_eye_origin_p_m: reader.read_f32_array::<3>(),
        left_eye_dir_p: reader.read_f32_array::<3>(),
        right_eye_origin_p_m: reader.read_f32_array::<3>(),
        right_eye_dir_p: reader.read_f32_array::<3>(),
        head_rot_p_f_q: reader.read_f32_array::<4>(),
        head_pos_p_m: reader.read_f32_array::<3>(),
        look_at_point_f_m: reader.read_f32_array::<3>(),
        confidence: reader.read_f32(),
        face_distance_m: reader.read_f32(),
    })
}

pub fn encode_envelope(envelope: &WireEnvelope) -> Vec<u8> {
    let mut out = Vec::with_capacity(WIRE_HEADER_LENGTH + envelope.payload.len());
    out.extend_from_slice(WIRE_MAGIC);
    out.extend_from_slice(&WIRE_VERSION.to_le_bytes());
    out.push(envelope.channel);
    out.push(envelope.kind);
    out.extend_from_slice(&(envelope.payload.len() as u32).to_le_bytes());
    out.extend_from_slice(&0_u32.to_le_bytes());
    out.extend_from_slice(&envelope.payload);
    out
}

pub fn decode_envelope(bytes: &[u8]) -> Result<WireEnvelope> {
    if bytes.len() < WIRE_HEADER_LENGTH {
        return Err(GazeHostError::FrameTooShort);
    }
    if &bytes[0..4] != WIRE_MAGIC {
        return Err(GazeHostError::BadMagic);
    }
    let version = u16::from_le_bytes([bytes[4], bytes[5]]);
    if version != WIRE_VERSION {
        return Err(GazeHostError::UnsupportedVersion(version));
    }
    let length = u32::from_le_bytes([bytes[8], bytes[9], bytes[10], bytes[11]]) as usize;
    if bytes.len() != WIRE_HEADER_LENGTH + length {
        return Err(GazeHostError::BadLength);
    }
    Ok(WireEnvelope {
        channel: bytes[6],
        kind: bytes[7],
        payload: bytes[WIRE_HEADER_LENGTH..].to_vec(),
    })
}

#[derive(Debug, Default)]
pub struct WireEnvelopeStreamDecoder {
    buffer: Vec<u8>,
}

impl WireEnvelopeStreamDecoder {
    pub fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    pub fn append(&mut self, bytes: &[u8]) {
        self.buffer.extend_from_slice(bytes);
    }

    pub fn next_envelope(&mut self) -> Result<Option<WireEnvelope>> {
        if self.buffer.len() < WIRE_HEADER_LENGTH {
            return Ok(None);
        }
        if &self.buffer[0..4] != WIRE_MAGIC {
            return Err(GazeHostError::BadMagic);
        }
        let version = u16::from_le_bytes([self.buffer[4], self.buffer[5]]);
        if version != WIRE_VERSION {
            return Err(GazeHostError::UnsupportedVersion(version));
        }
        let length = u32::from_le_bytes([self.buffer[8], self.buffer[9], self.buffer[10], self.buffer[11]]) as usize;
        let frame_length = WIRE_HEADER_LENGTH + length;
        if self.buffer.len() < frame_length {
            return Ok(None);
        }
        let envelope = WireEnvelope {
            channel: self.buffer[6],
            kind: self.buffer[7],
            payload: self.buffer[WIRE_HEADER_LENGTH..frame_length].to_vec(),
        };
        self.buffer.drain(0..frame_length);
        Ok(Some(envelope))
    }
}

fn append_f32_array<const N: usize>(out: &mut Vec<u8>, values: &[f32; N]) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

struct ByteReader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> ByteReader<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn read_u64(&mut self) -> u64 {
        let mut raw = [0_u8; 8];
        raw.copy_from_slice(&self.bytes[self.offset..self.offset + 8]);
        self.offset += 8;
        u64::from_le_bytes(raw)
    }

    fn read_u32(&mut self) -> u32 {
        let mut raw = [0_u8; 4];
        raw.copy_from_slice(&self.bytes[self.offset..self.offset + 4]);
        self.offset += 4;
        u32::from_le_bytes(raw)
    }

    fn read_f32(&mut self) -> f32 {
        f32::from_bits(self.read_u32())
    }

    fn read_f32_array<const N: usize>(&mut self) -> [f32; N] {
        std::array::from_fn(|_| self.read_f32())
    }
}
