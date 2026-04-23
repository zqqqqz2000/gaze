import Foundation
import GazeCoreC
import GazeProtocolKit

public enum GazeCoreError: Error, Equatable, LocalizedError {
    case invalidArgument
    case notEnoughData
    case numericFailure
    case outOfRange
    case bufferTooSmall
    case badEncoding
    case calibrationQuality
    case unknown(code: Int32)

    init(code: Int32) {
        switch code {
        case Int32(GAZE_ERROR_INVALID_ARGUMENT):
            self = .invalidArgument
        case Int32(GAZE_ERROR_NOT_ENOUGH_DATA):
            self = .notEnoughData
        case Int32(GAZE_ERROR_NUMERIC_FAILURE):
            self = .numericFailure
        case Int32(GAZE_ERROR_OUT_OF_RANGE):
            self = .outOfRange
        case Int32(GAZE_ERROR_BUFFER_TOO_SMALL):
            self = .bufferTooSmall
        case Int32(GAZE_ERROR_BAD_ENCODING):
            self = .badEncoding
        case Int32(GAZE_ERROR_CALIBRATION_QUALITY):
            self = .calibrationQuality
        default:
            self = .unknown(code: code)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidArgument:
            return "Invalid gaze core argument"
        case .notEnoughData:
            return "Not enough calibration data"
        case .numericFailure:
            return "Calibration solve failed numerically"
        case .outOfRange:
            return "Gaze ray does not intersect the calibrated screen plane"
        case .bufferTooSmall:
            return "Calibration buffer is too small"
        case .badEncoding:
            return "Calibration payload is not decodable"
        case .calibrationQuality:
            return "Calibration quality too low; please retry"
        case .unknown(let code):
            return "Unknown gaze core error: \(code)"
        }
    }
}

public struct GazeDisplayDescriptor: Sendable, Equatable {
    public var screenWidthMM: Float
    public var screenHeightMM: Float
    public var widthPixels: UInt32
    public var heightPixels: UInt32

    public init(screenWidthMM: Float, screenHeightMM: Float, widthPixels: UInt32, heightPixels: UInt32) {
        self.screenWidthMM = screenWidthMM
        self.screenHeightMM = screenHeightMM
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    fileprivate var rawValue: gaze_display_desc_t {
        gaze_display_desc_t(
            screen_width_mm: screenWidthMM,
            screen_height_mm: screenHeightMM,
            width_px: widthPixels,
            height_px: heightPixels
        )
    }
}

public struct GazeSolvedPoint: Sendable, Equatable {
    public var u: Float
    public var v: Float
    public var xPixels: Float
    public var yPixels: Float
    public var distanceToScreenPlaneM: Float
    public var rayPlaneAngleRad: Float
    public var confidence: Float
    public var insideScreen: Bool

    fileprivate init(rawValue: gaze_screen_point_t) {
        self.u = rawValue.u
        self.v = rawValue.v
        self.xPixels = rawValue.x_px
        self.yPixels = rawValue.y_px
        self.distanceToScreenPlaneM = rawValue.distance_to_screen_plane_m
        self.rayPlaneAngleRad = rawValue.ray_plane_angle_rad
        self.confidence = rawValue.confidence
        self.insideScreen = rawValue.inside_screen != 0
    }
}

public enum GazeCalibrationMode: Sendable {
    case full
    case quickRefit
    case validation

    fileprivate var rawValue: gaze_cal_mode_t {
        switch self {
        case .full:
            return GAZE_CAL_MODE_FULL
        case .quickRefit:
            return GAZE_CAL_MODE_QUICK_REFIT
        case .validation:
            return GAZE_CAL_MODE_VALIDATION
        }
    }
}

public struct GazeCalibration: Sendable {
    fileprivate var rawValue: gaze_calibration_t

    public var rmsePixels: Float { rawValue.rmse_px }
    public var medianErrorPixels: Float { rawValue.median_err_px }
    public var sampleCount: UInt32 { rawValue.sample_count }

    public var yawBiasRad: Float { rawValue.yaw_bias_rad }
    public var pitchBiasRad: Float { rawValue.pitch_bias_rad }
    public var yawGain: Float { rawValue.yaw_gain }
    public var pitchGain: Float { rawValue.pitch_gain }

    public var screenWidthMM: Float { rawValue.screen_width_mm }
    public var screenHeightMM: Float { rawValue.screen_height_mm }

    public var transformProviderFromScreen: [Float] {
        withUnsafeBytes(of: rawValue.T_provider_from_screen) { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }

    public var residualU: [Float] {
        withUnsafeBytes(of: rawValue.residual_u) { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }

    public var residualV: [Float] {
        withUnsafeBytes(of: rawValue.residual_v) { buf in
            Array(buf.bindMemory(to: Float.self))
        }
    }

    fileprivate init(rawValue: gaze_calibration_t) {
        self.rawValue = rawValue
    }

    public init(serializedData: Data) throws {
        var calibration = gaze_calibration_t()
        let result = serializedData.withUnsafeBytes { rawBuffer -> Int32 in
            gaze_calibration_deserialize(rawBuffer.baseAddress, rawBuffer.count, &calibration)
        }
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
        self.rawValue = calibration
    }

    public func serializedData() throws -> Data {
        var calibration = rawValue
        var data = Data(count: gaze_calibration_blob_size())
        let result = data.withUnsafeMutableBytes { rawBuffer -> Int32 in
            gaze_calibration_serialize(&calibration, rawBuffer.baseAddress, rawBuffer.count)
        }
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
        return data
    }

    public func solvePoint(sample: ProviderSamplePayload, display: GazeDisplayDescriptor) throws -> GazeSolvedPoint {
        var rawSample = makeProviderSample(sample)
        var rawCalibration = rawValue
        var rawDisplay = display.rawValue
        var point = gaze_screen_point_t()
        let result = gaze_solve_point(&rawSample, &rawCalibration, &rawDisplay, &point)
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
        return GazeSolvedPoint(rawValue: point)
    }
}

public final class GazeCalibrationSession {
    private let rawSession: OpaquePointer

    public init?(display: GazeDisplayDescriptor, mode: GazeCalibrationMode = .full) {
        var rawDisplay = display.rawValue
        guard let session = gaze_cal_begin(&rawDisplay, mode.rawValue) else {
            return nil
        }
        self.rawSession = session
    }

    deinit {
        gaze_cal_free(rawSession)
    }

    public func pushTarget(u: Float, v: Float, targetID: UInt32) throws {
        let result = gaze_cal_push_target(rawSession, u, v, targetID)
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
    }

    public func pushSample(_ sample: ProviderSamplePayload, targetID: UInt32) throws {
        var rawSample = makeProviderSample(sample)
        let result = gaze_cal_push_sample(rawSession, &rawSample, targetID)
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
    }

    public func solve() throws -> GazeCalibration {
        var calibration = gaze_calibration_t()
        let result = gaze_cal_solve(rawSession, &calibration)
        guard result == GAZE_OK else {
            throw GazeCoreError(code: result)
        }
        return GazeCalibration(rawValue: calibration)
    }

    public struct CalibrationResult: Sendable {
        public let calibration: GazeCalibration
        public let qualityAcceptable: Bool
    }

    public func solveWithQualityCheck() throws -> CalibrationResult {
        var calibration = gaze_calibration_t()
        let result = gaze_cal_solve(rawSession, &calibration)
        if result == GAZE_OK {
            return CalibrationResult(calibration: GazeCalibration(rawValue: calibration), qualityAcceptable: true)
        }
        if result == Int32(GAZE_ERROR_CALIBRATION_QUALITY) {
            return CalibrationResult(calibration: GazeCalibration(rawValue: calibration), qualityAcceptable: false)
        }
        throw GazeCoreError(code: result)
    }
}

private func makeProviderSample(_ sample: ProviderSamplePayload) -> gaze_provider_sample_t {
    var raw = gaze_provider_sample_t()
    raw.timestamp_ns = sample.timestampNs
    raw.tracking_flags = sample.trackingFlags
    copy(sample.gazeOriginPM, to: &raw.gaze_origin_p_m)
    copy(sample.gazeDirP, to: &raw.gaze_dir_p)
    copy(sample.leftEyeOriginPM, to: &raw.left_eye_origin_p_m)
    copy(sample.leftEyeDirP, to: &raw.left_eye_dir_p)
    copy(sample.rightEyeOriginPM, to: &raw.right_eye_origin_p_m)
    copy(sample.rightEyeDirP, to: &raw.right_eye_dir_p)
    copy(sample.headRotPFQ, to: &raw.head_rot_p_f_q)
    copy(sample.headPosPM, to: &raw.head_pos_p_m)
    copy(sample.lookAtPointFM, to: &raw.look_at_point_f_m)
    raw.confidence = sample.confidence
    raw.face_distance_m = sample.faceDistanceM
    return raw
}

private func copy(_ values: [Float], to storage: inout (Float, Float, Float)) {
    withUnsafeMutableBytes(of: &storage) { rawBuffer in
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        for index in 0..<min(values.count, 3) {
            rawBuffer.storeBytes(of: values[index], toByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
        }
    }
}

private func copy(_ values: [Float], to storage: inout (Float, Float, Float, Float)) {
    withUnsafeMutableBytes(of: &storage) { rawBuffer in
        rawBuffer.initializeMemory(as: UInt8.self, repeating: 0)
        for index in 0..<min(values.count, 4) {
            rawBuffer.storeBytes(of: values[index], toByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
        }
    }
}
