#include "gaze/gaze_sdk.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {

constexpr float kMetersPerMillimeter = 0.001f;
constexpr float kMinDirectionNorm = 1e-6f;
constexpr float kPlaneParallelEps = 1e-5f;
constexpr float kResidualFitRegularization = 0.01f;
constexpr float kPosConvergence = 1e-5f;
constexpr float kRotConvergence = 1e-5f;
constexpr float kBiasConvergence = 1e-6f;
constexpr uint8_t kCalibrationMagic[4] = {'G', 'Z', 'C', 'B'};
constexpr uint32_t kCalibrationEncodingVersion = 2u;

struct Vec2 {
    float x = 0.0f;
    float y = 0.0f;
};

struct Vec3 {
    float x = 0.0f;
    float y = 0.0f;
    float z = 0.0f;
};

struct Mat3 {
    Vec3 c0{1.0f, 0.0f, 0.0f};
    Vec3 c1{0.0f, 1.0f, 0.0f};
    Vec3 c2{0.0f, 0.0f, 1.0f};
};

struct TangentAffine {
    // Row-major 2x2 gain matrix operating on (yaw_raw, pitch_raw):
    //   [G_yy  G_yp]
    //   [G_py  G_pp]
    float G_yy = 1.0f;
    float G_yp = 0.0f;
    float G_py = 0.0f;
    float G_pp = 1.0f;
    float b_yaw = 0.0f;
    float b_pitch = 0.0f;

    static TangentAffine identity() { return TangentAffine{}; }
};

struct State {
    Mat3 rotation;
    Vec3 center;
    TangentAffine face_correction;
};

gaze_tangent_affine_t to_c_tangent_affine(const TangentAffine& t) {
    return gaze_tangent_affine_t{
        t.G_yy, t.G_yp, t.G_py, t.G_pp, t.b_yaw, t.b_pitch,
    };
}

TangentAffine from_c_tangent_affine(const gaze_tangent_affine_t& t) {
    return TangentAffine{t.G_yy, t.G_yp, t.G_py, t.G_pp, t.b_yaw, t.b_pitch};
}

struct Observation {
    Vec2 target_uv;
    gaze_provider_sample_t sample{};
};

struct DistancePrior {
    Vec3 mean_eye{0.0f, 0.0f, 0.0f};
    float mean_face_distance = 0.6f;
};

struct SolveStats {
    float rmse_px = 0.0f;
    float median_err_px = 0.0f;
};

Vec3 make_vec3(const float raw[3]) {
    return Vec3{raw[0], raw[1], raw[2]};
}

void store_vec3(const Vec3& value, float out[3]) {
    out[0] = value.x;
    out[1] = value.y;
    out[2] = value.z;
}

Vec3 operator+(const Vec3& a, const Vec3& b) {
    return Vec3{a.x + b.x, a.y + b.y, a.z + b.z};
}

Vec3 operator-(const Vec3& a, const Vec3& b) {
    return Vec3{a.x - b.x, a.y - b.y, a.z - b.z};
}

Vec3 operator*(const Vec3& a, float scalar) {
    return Vec3{a.x * scalar, a.y * scalar, a.z * scalar};
}

Vec3 operator*(float scalar, const Vec3& a) {
    return a * scalar;
}

Vec3 operator/(const Vec3& a, float scalar) {
    return Vec3{a.x / scalar, a.y / scalar, a.z / scalar};
}

float dot(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

Vec3 cross(const Vec3& a, const Vec3& b) {
    return Vec3{
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x,
    };
}

float norm(const Vec3& value) {
    return std::sqrt(dot(value, value));
}

Vec3 normalized(const Vec3& value) {
    const float length = norm(value);
    if (length < kMinDirectionNorm) {
        return Vec3{0.0f, 0.0f, 1.0f};
    }
    return value / length;
}

Mat3 identity_mat3() {
    return Mat3{};
}

Mat3 transpose(const Mat3& m) {
    return Mat3{
        Vec3{m.c0.x, m.c1.x, m.c2.x},
        Vec3{m.c0.y, m.c1.y, m.c2.y},
        Vec3{m.c0.z, m.c1.z, m.c2.z},
    };
}

Vec3 mul(const Mat3& m, const Vec3& v) {
    return m.c0 * v.x + m.c1 * v.y + m.c2 * v.z;
}

Mat3 mul(const Mat3& a, const Mat3& b) {
    return Mat3{
        mul(a, b.c0),
        mul(a, b.c1),
        mul(a, b.c2),
    };
}

Mat3 skew(const Vec3& axis) {
    return Mat3{
        Vec3{0.0f, axis.z, -axis.y},
        Vec3{-axis.z, 0.0f, axis.x},
        Vec3{axis.y, -axis.x, 0.0f},
    };
}

Mat3 add(const Mat3& a, const Mat3& b) {
    return Mat3{
        a.c0 + b.c0,
        a.c1 + b.c1,
        a.c2 + b.c2,
    };
}

Mat3 scale(const Mat3& a, float scalar) {
    return Mat3{
        a.c0 * scalar,
        a.c1 * scalar,
        a.c2 * scalar,
    };
}

Mat3 rotation_from_axis_angle(const Vec3& axis_angle) {
    const float angle = norm(axis_angle);
    if (angle < 1e-8f) {
        return identity_mat3();
    }
    const Vec3 axis = axis_angle / angle;
    const Mat3 k = skew(axis);
    const Mat3 kk = mul(k, k);
    return add(add(identity_mat3(), scale(k, std::sin(angle))), scale(kk, 1.0f - std::cos(angle)));
}

// Modified Gram-Schmidt: re-orthonormalize a 3x3 that should be SO(3) but
// has drifted due to accumulated float error across iterations.
Mat3 orthonormalize(const Mat3& m) {
    const Vec3 c0 = normalized(m.c0);
    Vec3 c1 = m.c1 - c0 * dot(m.c1, c0);
    c1 = normalized(c1);
    const Vec3 c2 = cross(c0, c1);
    return Mat3{c0, c1, c2};
}

Mat3 build_basis_from_normal(Vec3 z_axis, Vec3 up_hint = Vec3{0.0f, 1.0f, 0.0f}) {
    z_axis = normalized(z_axis);
    Vec3 x_axis = cross(up_hint, z_axis);
    if (norm(x_axis) < 1e-4f) {
        Vec3 fallback = (std::fabs(up_hint.y) > 0.9f)
            ? Vec3{0.0f, 0.0f, 1.0f}
            : Vec3{0.0f, 1.0f, 0.0f};
        x_axis = cross(fallback, z_axis);
    }
    x_axis = normalized(x_axis);
    const Vec3 y_axis = normalized(cross(z_axis, x_axis));
    return Mat3{x_axis, y_axis, z_axis};
}

Vec3 screen_point_to_provider(const gaze_display_desc_t& display, const Mat3& rotation, const Vec3& center, Vec2 uv) {
    const float width_m = display.screen_width_mm * kMetersPerMillimeter;
    const float height_m = display.screen_height_mm * kMetersPerMillimeter;
    const Vec3 screen_point{
        (uv.x - 0.5f) * width_m,
        (0.5f - uv.y) * height_m,
        0.0f,
    };
    return mul(rotation, screen_point) + center;
}

Mat3 mat3_from_quaternion(float qx, float qy, float qz, float qw) {
    const float xx = qx * qx, yy = qy * qy, zz = qz * qz;
    const float xy = qx * qy, xz = qx * qz, yz = qy * qz;
    const float wx = qw * qx, wy = qw * qy, wz = qw * qz;
    return Mat3{
        Vec3{1.0f - 2.0f * (yy + zz), 2.0f * (xy + wz), 2.0f * (xz - wy)},
        Vec3{2.0f * (xy - wz), 1.0f - 2.0f * (xx + zz), 2.0f * (yz + wx)},
        Vec3{2.0f * (xz + wy), 2.0f * (yz - wx), 1.0f - 2.0f * (xx + yy)},
    };
}

Mat3 head_rotation_from_sample(const gaze_provider_sample_t& sample) {
    const float qx = sample.head_rot_p_f_q[0];
    const float qy = sample.head_rot_p_f_q[1];
    const float qz = sample.head_rot_p_f_q[2];
    const float qw = sample.head_rot_p_f_q[3];
    const float norm_sq = qx * qx + qy * qy + qz * qz + qw * qw;
    if (norm_sq < 1e-8f) {
        return identity_mat3();
    }
    const float inv_norm = 1.0f / std::sqrt(norm_sq);
    return mat3_from_quaternion(qx * inv_norm, qy * inv_norm, qz * inv_norm, qw * inv_norm);
}

// Tait-Bryan decomposition of a unit vector in face frame with the convention
// forward = (0, 0, 1), up = (0, 1, 0), right = (1, 0, 0). Guards against
// gimbal lock near pitch = +/- pi/2 (i.e. gazing straight up/down, which
// cannot happen while looking at a screen in practice).
Vec2 tangent_from_direction(const Vec3& d_face) {
    const Vec3 n = normalized(d_face);
    constexpr float kEps = 1e-6f;
    const float y_clamped = std::max(-1.0f + kEps, std::min(1.0f - kEps, n.y));
    return Vec2{std::atan2(n.x, n.z), -std::asin(y_clamped)};
}

Vec3 direction_from_tangent(float yaw, float pitch) {
    const float sp = std::sin(pitch);
    const float cp = std::cos(pitch);
    return Vec3{std::sin(yaw) * cp, -sp, std::cos(yaw) * cp};
}

// Fast path for G = identity: avoids atan2 and asin by using the sum-of-angles
// identities on (sin yaw, cos yaw, sin pitch, cos pitch) computed directly from
// the direction components. Mathematically equivalent to the generic path when
// G == I, but replaces two transcendentals with one sqrt + a few MADDs.
Vec3 apply_identity_G_bias(const Vec3& d_face, float b_yaw, float b_pitch) {
    const Vec3 n = normalized(d_face);
    constexpr float kEps = 1e-6f;
    const float y_clamped = std::max(-1.0f + kEps, std::min(1.0f - kEps, n.y));
    const float horiz = std::sqrt(std::max(0.0f, 1.0f - y_clamped * y_clamped));
    const float sy = (horiz > kEps) ? n.x / horiz : 0.0f;
    const float cy = (horiz > kEps) ? n.z / horiz : 1.0f;
    const float sp0 = -y_clamped;
    const float cp0 = horiz;
    const float sby = std::sin(b_yaw);
    const float cby = std::cos(b_yaw);
    const float sbp = std::sin(b_pitch);
    const float cbp = std::cos(b_pitch);
    const float new_sy = sy * cby + cy * sby;
    const float new_cy = cy * cby - sy * sby;
    const float new_sp = sp0 * cbp + cp0 * sbp;
    const float new_cp = cp0 * cbp - sp0 * sbp;
    return Vec3{new_sy * new_cp, -new_sp, new_cy * new_cp};
}

inline bool is_identity_G(const TangentAffine& T) {
    return T.G_yy == 1.0f && T.G_pp == 1.0f && T.G_yp == 0.0f && T.G_py == 0.0f;
}

Vec3 apply_tangent_affine(const Vec3& d_face, const TangentAffine& T) {
    if (is_identity_G(T)) {
        return apply_identity_G_bias(d_face, T.b_yaw, T.b_pitch);
    }
    const Vec2 raw = tangent_from_direction(d_face);
    const float yaw_c = T.G_yy * raw.x + T.G_yp * raw.y + T.b_yaw;
    const float pitch_c = T.G_py * raw.x + T.G_pp * raw.y + T.b_pitch;
    return direction_from_tangent(yaw_c, pitch_c);
}

Vec3 correct_gaze_direction(
    const Vec3& direction,
    const TangentAffine& T,
    const Mat3& R_provider_from_face
) {
    const Mat3 R_face_from_provider = transpose(R_provider_from_face);
    const Vec3 dir_face = mul(R_face_from_provider, normalized(direction));
    const Vec3 dir_face_corr = apply_tangent_affine(dir_face, T);
    return normalized(mul(R_provider_from_face, dir_face_corr));
}

float clamp01(float value) {
    return std::min(1.0f, std::max(0.0f, value));
}

float apply_residual(const float coeffs[6], float u, float v) {
    return coeffs[0] + coeffs[1] * u + coeffs[2] * v + coeffs[3] * u * u + coeffs[4] * u * v + coeffs[5] * v * v;
}

bool intersect_ray_with_screen(
    const Vec3& origin,
    const Vec3& direction,
    const gaze_calibration_t& calibration,
    Vec3* out_hit,
    float* out_distance,
    float* out_angle
) {
    const Mat3 rotation{
        Vec3{
            calibration.T_provider_from_screen[0],
            calibration.T_provider_from_screen[1],
            calibration.T_provider_from_screen[2],
        },
        Vec3{
            calibration.T_provider_from_screen[4],
            calibration.T_provider_from_screen[5],
            calibration.T_provider_from_screen[6],
        },
        Vec3{
            calibration.T_provider_from_screen[8],
            calibration.T_provider_from_screen[9],
            calibration.T_provider_from_screen[10],
        },
    };
    const Vec3 center{
        calibration.T_provider_from_screen[12],
        calibration.T_provider_from_screen[13],
        calibration.T_provider_from_screen[14],
    };
    const Vec3 normal = normalized(rotation.c2);
    const float denom = dot(normal, direction);
    if (std::fabs(denom) < kPlaneParallelEps) {
        return false;
    }
    const float lambda = dot(normal, center - origin) / denom;
    if (lambda <= 0.0f) {
        return false;
    }
    *out_hit = origin + direction * lambda;
    *out_distance = std::fabs(dot(normal, origin - center));
    const float cosine = clamp01(std::fabs(dot(normalized(direction), normal)));
    *out_angle = std::asin(cosine);
    return true;
}

float compute_head_rotation_diversity_rad(const std::vector<Observation>& observations) {
    if (observations.size() < 2) {
        return 0.0f;
    }
    const float* q0 = observations[0].sample.head_rot_p_f_q;
    float mq[4] = {};
    for (const auto& obs : observations) {
        const float* q = obs.sample.head_rot_p_f_q;
        float sign = (q0[0] * q[0] + q0[1] * q[1] + q0[2] * q[2] + q0[3] * q[3]) < 0.0f ? -1.0f : 1.0f;
        for (int i = 0; i < 4; ++i) {
            mq[i] += sign * q[i];
        }
    }
    const float inv_n = 1.0f / static_cast<float>(observations.size());
    for (float& v : mq) {
        v *= inv_n;
    }
    float norm_sq = mq[0] * mq[0] + mq[1] * mq[1] + mq[2] * mq[2] + mq[3] * mq[3];
    if (norm_sq < 1e-8f) {
        return 0.0f;
    }
    const float inv_norm = 1.0f / std::sqrt(norm_sq);
    for (float& v : mq) {
        v *= inv_norm;
    }
    float max_angle = 0.0f;
    for (const auto& obs : observations) {
        const float* q = obs.sample.head_rot_p_f_q;
        float d = std::fabs(mq[0] * q[0] + mq[1] * q[1] + mq[2] * q[2] + mq[3] * q[3]);
        d = std::min(1.0f, d);
        max_angle = std::max(max_angle, 2.0f * std::acos(d));
    }
    return max_angle;
}

float adaptive_bias_regularization_weight(float diversity_rad) {
    constexpr float kLowDiversity = 0.05f;
    constexpr float kHighDiversity = 0.25f;
    constexpr float kWeightLow = 3.0f;
    constexpr float kWeightHigh = 0.5f;
    if (diversity_rad <= kLowDiversity) {
        return kWeightLow;
    }
    if (diversity_rad >= kHighDiversity) {
        return kWeightHigh;
    }
    const float t = (diversity_rad - kLowDiversity) / (kHighDiversity - kLowDiversity);
    return kWeightLow + t * (kWeightHigh - kWeightLow);
}

DistancePrior compute_distance_prior(const std::vector<Observation>& observations) {
    DistancePrior prior;
    if (observations.empty()) return prior;
    Vec3 sum{0.0f, 0.0f, 0.0f};
    float sum_fd = 0.0f;
    for (const auto& obs : observations) {
        sum = sum + make_vec3(obs.sample.gaze_origin_p_m);
        sum_fd += obs.sample.face_distance_m;
    }
    const float inv_n = 1.0f / static_cast<float>(observations.size());
    prior.mean_eye = sum * inv_n;
    prior.mean_face_distance = sum_fd * inv_n;
    if (prior.mean_face_distance < 0.1f || prior.mean_face_distance > 3.0f) {
        prior.mean_face_distance = 0.6f;
    }
    return prior;
}

constexpr float kDistanceRegWeight = 5.0f;

std::vector<float> build_residuals(
    const std::vector<Observation>& observations,
    const gaze_display_desc_t& display,
    const State& state,
    float bias_reg_weight,
    const DistancePrior& prior
) {
    std::vector<float> residuals;
    residuals.reserve(observations.size() * 3 + 3);
    for (const Observation& observation : observations) {
        const Vec3 origin = make_vec3(observation.sample.gaze_origin_p_m);
        const Vec3 raw_dir = make_vec3(observation.sample.gaze_dir_p);
        const Mat3 R_pf = head_rotation_from_sample(observation.sample);
        const Vec3 corrected_dir = correct_gaze_direction(raw_dir, state.face_correction, R_pf);
        const Vec3 target = screen_point_to_provider(display, state.rotation, state.center, observation.target_uv);
        const Vec3 expected_dir = normalized(target - origin);
        const float weight = std::max(0.2f, observation.sample.confidence);
        // Tangent-plane residual: |cross(a,b)| = sin(theta) for unit vectors.
        // This is a 3-vector with rank 2 (lies in the plane normal to expected_dir),
        // so has no radial redundancy and is linear in the small-angle limit.
        const Vec3 delta = cross(corrected_dir, expected_dir) * weight;
        residuals.push_back(delta.x);
        residuals.push_back(delta.y);
        residuals.push_back(delta.z);
    }
    residuals.push_back(state.face_correction.b_yaw * bias_reg_weight);
    residuals.push_back(state.face_correction.b_pitch * bias_reg_weight);

    const Vec3 diff = state.center - prior.mean_eye;
    const float dist = std::sqrt(diff.x * diff.x + diff.y * diff.y + diff.z * diff.z);
    residuals.push_back((dist - prior.mean_face_distance) * kDistanceRegWeight);

    return residuals;
}

State apply_delta(const State& state, const std::vector<float>& delta, bool include_bias) {
    State next = state;
    next.center = next.center + Vec3{delta[0], delta[1], delta[2]};
    const Mat3 delta_rotation = rotation_from_axis_angle(Vec3{delta[3], delta[4], delta[5]});
    next.rotation = orthonormalize(mul(delta_rotation, next.rotation));
    if (include_bias) {
        next.face_correction.b_yaw += delta[6];
        next.face_correction.b_pitch += delta[7];
    }
    return next;
}

bool solve_linear_system(std::vector<float> matrix, std::vector<float> rhs, int dimension, std::vector<float>* out_solution) {
    for (int i = 0; i < dimension; ++i) {
        int pivot = i;
        float pivot_value = std::fabs(matrix[i * dimension + i]);
        for (int row = i + 1; row < dimension; ++row) {
            const float candidate = std::fabs(matrix[row * dimension + i]);
            if (candidate > pivot_value) {
                pivot = row;
                pivot_value = candidate;
            }
        }
        if (pivot_value < 1e-9f) {
            return false;
        }
        if (pivot != i) {
            for (int col = 0; col < dimension; ++col) {
                std::swap(matrix[i * dimension + col], matrix[pivot * dimension + col]);
            }
            std::swap(rhs[i], rhs[pivot]);
        }
        const float diag = matrix[i * dimension + i];
        for (int col = i; col < dimension; ++col) {
            matrix[i * dimension + col] /= diag;
        }
        rhs[i] /= diag;
        for (int row = 0; row < dimension; ++row) {
            if (row == i) {
                continue;
            }
            const float factor = matrix[row * dimension + i];
            if (std::fabs(factor) < 1e-12f) {
                continue;
            }
            for (int col = i; col < dimension; ++col) {
                matrix[row * dimension + col] -= factor * matrix[i * dimension + col];
            }
            rhs[row] -= factor * rhs[i];
        }
    }
    *out_solution = std::move(rhs);
    return true;
}

bool gauss_newton_optimize(
    const std::vector<Observation>& observations,
    const gaze_display_desc_t& display,
    State* state,
    bool optimize_bias,
    float bias_reg_weight,
    const DistancePrior& prior
) {
    const int parameter_count = optimize_bias ? 8 : 6;
    if (observations.size() < 4) {
        return false;
    }

    // Per-parameter finite-difference step sizes. Using the same eps across
    // parameters with different natural scales (meters vs radians) wastes
    // precision on the small-scale parameters; these values are tuned
    // for float32 cancellation error near optimum.
    constexpr float kFdEps[8] = {
        1e-4f, 1e-4f, 1e-4f,  // center (m)
        1e-4f, 1e-4f, 1e-4f,  // rotation axis-angle (rad)
        1e-4f, 1e-4f,         // b_yaw, b_pitch (rad)
    };

    float damping = 1e-3f;
    for (int iteration = 0; iteration < 30; ++iteration) {
        const std::vector<float> residuals = build_residuals(observations, display, *state, bias_reg_weight, prior);
        const std::size_t residual_count = residuals.size();

        std::vector<float> jacobian(residual_count * static_cast<std::size_t>(parameter_count), 0.0f);
        for (int param = 0; param < parameter_count; ++param) {
            const float eps = kFdEps[param];
            std::vector<float> plus_delta(parameter_count, 0.0f);
            std::vector<float> minus_delta(parameter_count, 0.0f);
            plus_delta[param] = eps;
            minus_delta[param] = -eps;
            const State plus_state = apply_delta(*state, plus_delta, optimize_bias);
            const State minus_state = apply_delta(*state, minus_delta, optimize_bias);
            const auto plus_residuals = build_residuals(observations, display, plus_state, bias_reg_weight, prior);
            const auto minus_residuals = build_residuals(observations, display, minus_state, bias_reg_weight, prior);
            const float inv_two_eps = 1.0f / (2.0f * eps);
            for (std::size_t row = 0; row < residual_count; ++row) {
                jacobian[row * static_cast<std::size_t>(parameter_count) + static_cast<std::size_t>(param)] =
                    (plus_residuals[row] - minus_residuals[row]) * inv_two_eps;
            }
        }

        std::vector<float> jt_j(static_cast<std::size_t>(parameter_count * parameter_count), 0.0f);
        std::vector<float> jt_r(static_cast<std::size_t>(parameter_count), 0.0f);
        for (std::size_t row = 0; row < residual_count; ++row) {
            for (int i = 0; i < parameter_count; ++i) {
                const float ji = jacobian[row * static_cast<std::size_t>(parameter_count) + static_cast<std::size_t>(i)];
                jt_r[static_cast<std::size_t>(i)] += ji * residuals[row];
                for (int j = 0; j < parameter_count; ++j) {
                    const float jj =
                        jacobian[row * static_cast<std::size_t>(parameter_count) + static_cast<std::size_t>(j)];
                    jt_j[static_cast<std::size_t>(i * parameter_count + j)] += ji * jj;
                }
            }
        }
        // Marquardt scaling: damp each parameter proportionally to its own
        // diagonal, so parameters with different natural scales (position m
        // vs angle rad) are regularised consistently.
        for (int i = 0; i < parameter_count; ++i) {
            const std::size_t idx = static_cast<std::size_t>(i * parameter_count + i);
            const float diag = jt_j[idx];
            jt_j[idx] = diag + damping * std::max(diag, 1e-9f);
            jt_r[static_cast<std::size_t>(i)] = -jt_r[static_cast<std::size_t>(i)];
        }

        std::vector<float> step;
        if (!solve_linear_system(jt_j, jt_r, parameter_count, &step)) {
            return false;
        }

        const float pos_step2 = step[0] * step[0] + step[1] * step[1] + step[2] * step[2];
        const float rot_step2 = step[3] * step[3] + step[4] * step[4] + step[5] * step[5];
        const float bias_step2 = optimize_bias ? (step[6] * step[6] + step[7] * step[7]) : 0.0f;
        if (std::sqrt(pos_step2) < kPosConvergence &&
            std::sqrt(rot_step2) < kRotConvergence &&
            std::sqrt(bias_step2) < kBiasConvergence) {
            return true;
        }

        const State candidate = apply_delta(*state, step, optimize_bias);
        const std::vector<float> candidate_residuals = build_residuals(observations, display, candidate, bias_reg_weight, prior);

        float current_cost = 0.0f;
        float candidate_cost = 0.0f;
        for (float value : residuals) {
            current_cost += value * value;
        }
        for (float value : candidate_residuals) {
            candidate_cost += value * value;
        }

        if (candidate_cost < current_cost) {
            *state = candidate;
            damping = std::max(1e-6f, damping * 0.5f);
        } else {
            damping = std::min(1.0f, damping * 4.0f);
        }
    }
    return true;
}

Vec3 estimate_screen_center(const std::vector<Observation>& observations) {
    Vec3 avg_origin{0.0f, 0.0f, 0.0f};
    Vec3 avg_dir{0.0f, 0.0f, 0.0f};
    float avg_fd = 0.0f;
    const float inv_n = 1.0f / static_cast<float>(std::max(std::size_t(1), observations.size()));
    for (const Observation& obs : observations) {
        avg_origin = avg_origin + make_vec3(obs.sample.gaze_origin_p_m);
        avg_dir = avg_dir + normalized(make_vec3(obs.sample.gaze_dir_p));
        avg_fd += obs.sample.face_distance_m;
    }
    avg_origin = avg_origin * inv_n;
    avg_dir = normalized(avg_dir);
    avg_fd *= inv_n;
    if (avg_fd < 0.1f || avg_fd > 3.0f) avg_fd = 0.6f;
    return avg_origin + avg_dir * avg_fd;
}

Vec3 estimate_up_from_observations(const std::vector<Observation>& observations, const Vec3& screen_normal) {
    Vec3 sum_delta{0.0f, 0.0f, 0.0f};
    int count = 0;
    for (const auto& obs : observations) {
        if (obs.target_uv.y < 0.35f) {
            for (const auto& other : observations) {
                if (other.target_uv.y > 0.65f &&
                    std::fabs(obs.target_uv.x - other.target_uv.x) < 0.1f) {
                    const Vec3 d_top = normalized(make_vec3(obs.sample.gaze_dir_p));
                    const Vec3 d_bot = normalized(make_vec3(other.sample.gaze_dir_p));
                    // Normalise each pair before averaging so long / short
                    // eye-to-target baselines contribute equally.
                    const Vec3 delta = d_top - d_bot;
                    if (norm(delta) > 1e-4f) {
                        sum_delta = sum_delta + normalized(delta);
                        ++count;
                    }
                }
            }
        }
    }
    if (count > 0) {
        Vec3 up_candidate = normalized(sum_delta);
        Vec3 up_on_plane = up_candidate - screen_normal * dot(up_candidate, screen_normal);
        if (norm(up_on_plane) > 1e-4f) {
            return normalized(up_on_plane);
        }
    }
    return Vec3{0.0f, 1.0f, 0.0f};
}

constexpr float kCalibrationQualityRmsePxThreshold = 200.0f;

struct StatePair {
    State primary;
    State alternate;
};

StatePair make_dual_initial_states(const std::vector<Observation>& observations, const gaze_display_desc_t& display, const DistancePrior& prior) {
    const Vec3 center = estimate_screen_center(observations);

    Vec3 avg_dir{0.0f, 0.0f, 0.0f};
    for (const Observation& observation : observations) {
        avg_dir = avg_dir + normalized(make_vec3(observation.sample.gaze_dir_p));
    }
    avg_dir = normalized(avg_dir);

    const Vec3 up_hint = estimate_up_from_observations(observations, avg_dir);

    State s_fwd;
    s_fwd.center = center;
    s_fwd.rotation = build_basis_from_normal(avg_dir, up_hint);

    State s_bwd;
    s_bwd.center = center;
    s_bwd.rotation = build_basis_from_normal(-1.0f * avg_dir, up_hint);

    const auto r_fwd = build_residuals(observations, display, s_fwd, 0.0f, prior);
    const auto r_bwd = build_residuals(observations, display, s_bwd, 0.0f, prior);
    float cost_fwd = 0.0f, cost_bwd = 0.0f;
    for (float v : r_fwd) cost_fwd += v * v;
    for (float v : r_bwd) cost_bwd += v * v;

    if (cost_fwd <= cost_bwd)
        return {s_fwd, s_bwd};
    return {s_bwd, s_fwd};
}

float direction_cost(const std::vector<Observation>& observations, const gaze_display_desc_t& display, const State& s, const DistancePrior& prior) {
    const auto r = build_residuals(observations, display, s, 0.0f, prior);
    const std::size_t dir_count = observations.size() * 3;
    float c = 0.0f;
    for (std::size_t i = 0; i < dir_count && i < r.size(); ++i) c += r[i] * r[i];
    return c;
}

void store_transform(const State& state, float out[16]) {
    out[0] = state.rotation.c0.x;
    out[1] = state.rotation.c0.y;
    out[2] = state.rotation.c0.z;
    out[3] = 0.0f;

    out[4] = state.rotation.c1.x;
    out[5] = state.rotation.c1.y;
    out[6] = state.rotation.c1.z;
    out[7] = 0.0f;

    out[8] = state.rotation.c2.x;
    out[9] = state.rotation.c2.y;
    out[10] = state.rotation.c2.z;
    out[11] = 0.0f;

    out[12] = state.center.x;
    out[13] = state.center.y;
    out[14] = state.center.z;
    out[15] = 1.0f;
}

float pixel_error_for_observation(
    const Observation& observation,
    const gaze_calibration_t& calibration,
    const gaze_display_desc_t& display
) {
    gaze_screen_point_t point{};
    if (gaze_solve_point(&observation.sample, &calibration, &display, &point) != GAZE_OK) {
        return 1e6f;
    }
    const float dx = point.x_px - observation.target_uv.x * static_cast<float>(display.width_px);
    const float dy = point.y_px - observation.target_uv.y * static_cast<float>(display.height_px);
    return std::sqrt(dx * dx + dy * dy);
}

SolveStats compute_solve_stats(
    const std::vector<Observation>& observations,
    const gaze_calibration_t& calibration,
    const gaze_display_desc_t& display
) {
    if (observations.empty()) {
        return SolveStats{};
    }
    std::vector<float> errors;
    errors.reserve(observations.size());
    float squared_sum = 0.0f;
    for (const Observation& observation : observations) {
        const float error = pixel_error_for_observation(observation, calibration, display);
        errors.push_back(error);
        squared_sum += error * error;
    }
    std::sort(errors.begin(), errors.end());
    SolveStats stats;
    stats.rmse_px = std::sqrt(squared_sum / static_cast<float>(errors.size()));
    stats.median_err_px = errors[errors.size() / 2];
    return stats;
}

State load_state_from_calibration(const gaze_calibration_t& calibration) {
    return State{
        Mat3{
            Vec3{
                calibration.T_provider_from_screen[0],
                calibration.T_provider_from_screen[1],
                calibration.T_provider_from_screen[2],
            },
            Vec3{
                calibration.T_provider_from_screen[4],
                calibration.T_provider_from_screen[5],
                calibration.T_provider_from_screen[6],
            },
            Vec3{
                calibration.T_provider_from_screen[8],
                calibration.T_provider_from_screen[9],
                calibration.T_provider_from_screen[10],
            },
        },
        Vec3{
            calibration.T_provider_from_screen[12],
            calibration.T_provider_from_screen[13],
            calibration.T_provider_from_screen[14],
        },
        from_c_tangent_affine(calibration.no_glasses),
    };
}

void fill_calibration(
    const State& state,
    const gaze_display_desc_t& display,
    const SolveStats& stats,
    uint32_t sample_count,
    gaze_calibration_t* out_calibration
) {
    out_calibration->version = 2.0f;
    out_calibration->screen_width_mm = display.screen_width_mm;
    out_calibration->screen_height_mm = display.screen_height_mm;
    store_transform(state, out_calibration->T_provider_from_screen);
    out_calibration->no_glasses = to_c_tangent_affine(state.face_correction);
    out_calibration->glasses = to_c_tangent_affine(TangentAffine::identity());
    out_calibration->has_glasses = 0u;
    out_calibration->active_state = GAZE_STATE_NO_GLASSES;
    std::fill(std::begin(out_calibration->residual_u), std::end(out_calibration->residual_u), 0.0f);
    std::fill(std::begin(out_calibration->residual_v), std::end(out_calibration->residual_v), 0.0f);
    out_calibration->rmse_px = stats.rmse_px;
    out_calibration->median_err_px = stats.median_err_px;
    out_calibration->sample_count = sample_count;
}

bool valid_uv(float u, float v) {
    return std::isfinite(u) && std::isfinite(v) && u >= 0.0f && u <= 1.0f && v >= 0.0f && v <= 1.0f;
}

bool valid_display(const gaze_display_desc_t* display) {
    return display != nullptr && display->screen_width_mm > 0.0f && display->screen_height_mm > 0.0f &&
           display->width_px > 0 && display->height_px > 0;
}

void write_u32_le(uint8_t* buffer, size_t offset, uint32_t value) {
    buffer[offset + 0] = static_cast<uint8_t>(value & 0xffu);
    buffer[offset + 1] = static_cast<uint8_t>((value >> 8u) & 0xffu);
    buffer[offset + 2] = static_cast<uint8_t>((value >> 16u) & 0xffu);
    buffer[offset + 3] = static_cast<uint8_t>((value >> 24u) & 0xffu);
}

uint32_t read_u32_le(const uint8_t* buffer, size_t offset) {
    return static_cast<uint32_t>(buffer[offset + 0]) |
           (static_cast<uint32_t>(buffer[offset + 1]) << 8u) |
           (static_cast<uint32_t>(buffer[offset + 2]) << 16u) |
           (static_cast<uint32_t>(buffer[offset + 3]) << 24u);
}

void write_f32_le(uint8_t* buffer, size_t offset, float value) {
    uint32_t bits = 0u;
    std::memcpy(&bits, &value, sizeof(bits));
    write_u32_le(buffer, offset, bits);
}

float read_f32_le(const uint8_t* buffer, size_t offset) {
    const uint32_t bits = read_u32_le(buffer, offset);
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

}  // namespace

struct gaze_cal_session {
    gaze_display_desc_t display{};
    gaze_cal_mode_t mode = GAZE_CAL_MODE_FULL;
    std::unordered_map<uint32_t, Vec2> targets;
    std::vector<Observation> observations;
    // Only used by GAZE_CAL_MODE_GLASSES: the frozen no-glasses baseline.
    // Mode is still owned by `mode`; this field is just the snapshot.
    gaze_calibration_t baseline_calibration{};
    bool has_baseline = false;
};

const char* gaze_get_version_string(void) {
    return "gaze-sdk/0.1.0";
}

gaze_cal_session_t* gaze_cal_begin(const gaze_display_desc_t* display, gaze_cal_mode_t mode) {
    if (!valid_display(display)) {
        return nullptr;
    }
    auto* session = new gaze_cal_session_t();
    session->display = *display;
    session->mode = mode;
    return session;
}

void gaze_cal_free(gaze_cal_session_t* session) {
    delete session;
}

int gaze_cal_push_target(gaze_cal_session_t* session, float u, float v, uint32_t target_id) {
    if (session == nullptr || !valid_uv(u, v)) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    session->targets[target_id] = Vec2{u, v};
    return GAZE_OK;
}

int gaze_cal_push_sample(
    gaze_cal_session_t* session,
    const gaze_provider_sample_t* sample,
    uint32_t target_id
) {
    if (session == nullptr || sample == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    const auto target_it = session->targets.find(target_id);
    if (target_it == session->targets.end()) {
        return GAZE_ERROR_OUT_OF_RANGE;
    }
    session->observations.push_back(Observation{target_it->second, *sample});
    return GAZE_OK;
}

void fit_residual_polynomials(
    const std::vector<Observation>& observations,
    const gaze_calibration_t& calibration,
    const gaze_display_desc_t& display,
    float out_residual_u[6],
    float out_residual_v[6]
) {
    std::fill(out_residual_u, out_residual_u + 6, 0.0f);
    std::fill(out_residual_v, out_residual_v + 6, 0.0f);

    struct TargetAccum {
        Vec2 target{};
        double sum_u = 0.0;
        double sum_v = 0.0;
        int count = 0;
    };
    std::vector<TargetAccum> targets;

    for (const Observation& obs : observations) {
        TargetAccum* found = nullptr;
        for (auto& t : targets) {
            if (std::fabs(t.target.x - obs.target_uv.x) < 0.01f &&
                std::fabs(t.target.y - obs.target_uv.y) < 0.01f) {
                found = &t;
                break;
            }
        }
        if (!found) {
            targets.push_back(TargetAccum{obs.target_uv, 0.0, 0.0, 0});
            found = &targets.back();
        }
        gaze_screen_point_t point{};
        if (gaze_solve_point(&obs.sample, &calibration, &display, &point) == GAZE_OK) {
            found->sum_u += point.u;
            found->sum_v += point.v;
            found->count++;
        }
    }

    int valid_count = 0;
    for (const auto& t : targets) {
        if (t.count > 0) {
            ++valid_count;
        }
    }
    if (valid_count < 3) {
        return;
    }

    constexpr int kCoeffs = 6;
    std::vector<float> xt_x(kCoeffs * kCoeffs, 0.0f);
    std::vector<float> xt_du(kCoeffs, 0.0f);
    std::vector<float> xt_dv(kCoeffs, 0.0f);

    for (const auto& t : targets) {
        if (t.count == 0) {
            continue;
        }
        const float mu = static_cast<float>(t.sum_u / t.count);
        const float mv = static_cast<float>(t.sum_v / t.count);
        const float du = t.target.x - mu;
        const float dv = t.target.y - mv;
        const float row[kCoeffs] = {1.0f, mu, mv, mu * mu, mu * mv, mv * mv};
        for (int i = 0; i < kCoeffs; ++i) {
            xt_du[i] += row[i] * du;
            xt_dv[i] += row[i] * dv;
            for (int j = 0; j < kCoeffs; ++j) {
                xt_x[i * kCoeffs + j] += row[i] * row[j];
            }
        }
    }

    for (int i = 0; i < kCoeffs; ++i) {
        xt_x[i * kCoeffs + i] += kResidualFitRegularization;
    }

    {
        auto mat = xt_x;
        auto rhs = xt_du;
        std::vector<float> sol;
        if (solve_linear_system(mat, rhs, kCoeffs, &sol)) {
            std::copy(sol.begin(), sol.end(), out_residual_u);
        }
    }
    {
        auto mat = xt_x;
        auto rhs = xt_dv;
        std::vector<float> sol;
        if (solve_linear_system(mat, rhs, kCoeffs, &sol)) {
            std::copy(sol.begin(), sol.end(), out_residual_v);
        }
    }
}

int gaze_cal_solve(gaze_cal_session_t* session, gaze_calibration_t* out_calibration) {
    if (session == nullptr || out_calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (session->observations.size() < 6) {
        return GAZE_ERROR_NOT_ENOUGH_DATA;
    }

    const float diversity = compute_head_rotation_diversity_rad(session->observations);
    const float reg_weight = adaptive_bias_regularization_weight(diversity);
    const DistancePrior prior = compute_distance_prior(session->observations);

    auto [s1, s2] = make_dual_initial_states(session->observations, session->display, prior);

    gauss_newton_optimize(session->observations, session->display, &s1, false, 0.0f, prior);
    gauss_newton_optimize(session->observations, session->display, &s2, false, 0.0f, prior);

    const bool ok1 = gauss_newton_optimize(session->observations, session->display, &s1, true, reg_weight, prior);
    const bool ok2 = gauss_newton_optimize(session->observations, session->display, &s2, true, reg_weight, prior);

    if (!ok1 && !ok2) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }

    State state;
    if (ok1 && ok2) {
        const float c1 = direction_cost(session->observations, session->display, s1, prior);
        const float c2 = direction_cost(session->observations, session->display, s2, prior);
        state = (c1 <= c2) ? s1 : s2;
    } else {
        state = ok1 ? s1 : s2;
    }

    gaze_calibration_t calibration{};
    const uint32_t n = static_cast<uint32_t>(session->observations.size());
    fill_calibration(state, session->display, SolveStats{}, n, &calibration);

    fit_residual_polynomials(session->observations, calibration, session->display,
                             calibration.residual_u, calibration.residual_v);

    const SolveStats stats = compute_solve_stats(session->observations, calibration, session->display);
    calibration.rmse_px = stats.rmse_px;
    calibration.median_err_px = stats.median_err_px;

    *out_calibration = calibration;

    if (stats.rmse_px > kCalibrationQualityRmsePxThreshold) {
        return GAZE_ERROR_CALIBRATION_QUALITY;
    }
    return GAZE_OK;
}

gaze_cal_session_t* gaze_cal_begin_glasses(
    const gaze_display_desc_t* display,
    const gaze_calibration_t* baseline_no_glasses
) {
    if (!valid_display(display) || baseline_no_glasses == nullptr) {
        return nullptr;
    }
    auto* session = new gaze_cal_session_t();
    session->display = *display;
    session->mode = GAZE_CAL_MODE_GLASSES;
    session->baseline_calibration = *baseline_no_glasses;
    session->has_baseline = true;
    return session;
}

int gaze_cal_solve_glasses(gaze_cal_session_t* session, gaze_calibration_t* out_calibration) {
    if (session == nullptr || out_calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (session->mode != GAZE_CAL_MODE_GLASSES || !session->has_baseline) {
        return GAZE_ERROR_MISSING_BASELINE;
    }
    if (session->observations.size() < 4) {
        return GAZE_ERROR_NOT_ENOUGH_DATA;
    }

    // Freeze pose from baseline; fit only the glasses tangent-affine (G_g, b_g)
    // to map raw ARKit tangent -> expected tangent in face frame. This is a
    // 2 x (N linear-least-squares) problem: the yaw and pitch axes are
    // independent given fixed screen pose.
    const State base_state = load_state_from_calibration(session->baseline_calibration);

    const std::size_t n = session->observations.size();
    std::vector<std::array<float, 3>> A;
    std::vector<float> y_yaw;
    std::vector<float> y_pitch;
    A.reserve(n);
    y_yaw.reserve(n);
    y_pitch.reserve(n);

    for (const auto& obs : session->observations) {
        const Vec3 origin = make_vec3(obs.sample.gaze_origin_p_m);
        const Vec3 raw_dir = make_vec3(obs.sample.gaze_dir_p);
        const Mat3 R_pf = head_rotation_from_sample(obs.sample);
        const Mat3 R_fp = transpose(R_pf);
        const Vec3 raw_face = mul(R_fp, normalized(raw_dir));
        const Vec2 raw_t = tangent_from_direction(raw_face);

        const Vec3 target = screen_point_to_provider(session->display, base_state.rotation, base_state.center, obs.target_uv);
        const Vec3 expected_dir = normalized(target - origin);
        const Vec3 exp_face = mul(R_fp, expected_dir);
        const Vec2 exp_t = tangent_from_direction(exp_face);

        A.push_back({raw_t.x, raw_t.y, 1.0f});
        y_yaw.push_back(exp_t.x);
        y_pitch.push_back(exp_t.y);
    }

    // Ridge-regularised normal equations with prior mean at identity:
    //   yaw axis:   prior = [1, 0, 0]   (G_yy=1, G_yp=0, b_yaw=0)
    //   pitch axis: prior = [0, 1, 0]   (G_py=0, G_pp=1, b_pitch=0)
    // The small regulariser keeps the solver stable when the user only
    // samples near-frontal head poses (low head-rotation diversity).
    constexpr float kLambda = 0.01f;
    float ATA[9] = {0.0f};
    float ATy_yaw[3] = {0.0f};
    float ATy_pitch[3] = {0.0f};
    for (std::size_t k = 0; k < n; ++k) {
        for (int i = 0; i < 3; ++i) {
            for (int j = 0; j < 3; ++j) {
                ATA[i * 3 + j] += A[k][i] * A[k][j];
            }
            ATy_yaw[i] += A[k][i] * y_yaw[k];
            ATy_pitch[i] += A[k][i] * y_pitch[k];
        }
    }
    for (int i = 0; i < 3; ++i) {
        ATA[i * 3 + i] += kLambda;
    }
    ATy_yaw[0]   += kLambda * 1.0f;
    ATy_pitch[1] += kLambda * 1.0f;

    std::vector<float> mat_yaw(ATA, ATA + 9);
    std::vector<float> rhs_yaw(ATy_yaw, ATy_yaw + 3);
    std::vector<float> x_yaw;
    if (!solve_linear_system(mat_yaw, rhs_yaw, 3, &x_yaw)) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }
    std::vector<float> mat_pitch(ATA, ATA + 9);
    std::vector<float> rhs_pitch(ATy_pitch, ATy_pitch + 3);
    std::vector<float> x_pitch;
    if (!solve_linear_system(mat_pitch, rhs_pitch, 3, &x_pitch)) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }

    TangentAffine glasses{};
    glasses.G_yy = x_yaw[0];
    glasses.G_yp = x_yaw[1];
    glasses.b_yaw = x_yaw[2];
    glasses.G_py = x_pitch[0];
    glasses.G_pp = x_pitch[1];
    glasses.b_pitch = x_pitch[2];

    gaze_calibration_t calibration = session->baseline_calibration;
    calibration.glasses = to_c_tangent_affine(glasses);
    calibration.has_glasses = 1u;
    calibration.active_state = GAZE_STATE_GLASSES;
    calibration.sample_count = static_cast<uint32_t>(n);

    const SolveStats stats = compute_solve_stats(session->observations, calibration, session->display);
    calibration.rmse_px = stats.rmse_px;
    calibration.median_err_px = stats.median_err_px;

    *out_calibration = calibration;

    if (stats.rmse_px > kCalibrationQualityRmsePxThreshold) {
        return GAZE_ERROR_CALIBRATION_QUALITY;
    }
    return GAZE_OK;
}

int gaze_set_active_state(gaze_calibration_t* calibration, uint32_t state) {
    if (calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (state != GAZE_STATE_NO_GLASSES && state != GAZE_STATE_GLASSES) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (state == GAZE_STATE_GLASSES && calibration->has_glasses == 0u) {
        return GAZE_ERROR_MISSING_BASELINE;
    }
    calibration->active_state = state;
    return GAZE_OK;
}

int gaze_solve_point(
    const gaze_provider_sample_t* sample,
    const gaze_calibration_t* calibration,
    const gaze_display_desc_t* display,
    gaze_screen_point_t* out_point
) {
    if (sample == nullptr || calibration == nullptr || display == nullptr || out_point == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (!valid_display(display)) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }

    const Vec3 origin = make_vec3(sample->gaze_origin_p_m);
    const Vec3 raw_dir = make_vec3(sample->gaze_dir_p);
    const Mat3 R_pf = head_rotation_from_sample(*sample);
    const TangentAffine face_correction =
        (calibration->active_state == GAZE_STATE_GLASSES && calibration->has_glasses != 0u)
            ? from_c_tangent_affine(calibration->glasses)
            : from_c_tangent_affine(calibration->no_glasses);
    const Vec3 direction = correct_gaze_direction(raw_dir, face_correction, R_pf);

    Vec3 hit{};
    float plane_distance = 0.0f;
    float angle = 0.0f;
    if (!intersect_ray_with_screen(origin, direction, *calibration, &hit, &plane_distance, &angle)) {
        return GAZE_ERROR_OUT_OF_RANGE;
    }

    const Mat3 rotation{
        Vec3{
            calibration->T_provider_from_screen[0],
            calibration->T_provider_from_screen[1],
            calibration->T_provider_from_screen[2],
        },
        Vec3{
            calibration->T_provider_from_screen[4],
            calibration->T_provider_from_screen[5],
            calibration->T_provider_from_screen[6],
        },
        Vec3{
            calibration->T_provider_from_screen[8],
            calibration->T_provider_from_screen[9],
            calibration->T_provider_from_screen[10],
        },
    };
    const Vec3 center{
        calibration->T_provider_from_screen[12],
        calibration->T_provider_from_screen[13],
        calibration->T_provider_from_screen[14],
    };
    const Vec3 hit_screen = mul(transpose(rotation), hit - center);
    const float width_m = calibration->screen_width_mm * kMetersPerMillimeter;
    const float height_m = calibration->screen_height_mm * kMetersPerMillimeter;
    float u = hit_screen.x / width_m + 0.5f;
    float v = 0.5f - hit_screen.y / height_m;

    const float residual_u = apply_residual(calibration->residual_u, u, v);
    const float residual_v = apply_residual(calibration->residual_v, u, v);
    u += residual_u;
    v += residual_v;

    out_point->u = u;
    out_point->v = v;
    out_point->x_px = u * static_cast<float>(display->width_px);
    out_point->y_px = v * static_cast<float>(display->height_px);
    store_vec3(hit, out_point->hit_point_p_m);
    out_point->distance_to_screen_plane_m = plane_distance;
    out_point->ray_plane_angle_rad = angle;
    out_point->confidence = sample->confidence;
    out_point->inside_screen = (u >= 0.0f && u <= 1.0f && v >= 0.0f && v <= 1.0f) ? 1u : 0u;
    return GAZE_OK;
}

int gaze_refit_pose(
    const gaze_calibration_t* base_calibration,
    const gaze_display_desc_t* display,
    const gaze_refit_observation_t* observations,
    size_t observation_count,
    gaze_calibration_t* out_calibration
) {
    if (base_calibration == nullptr || display == nullptr || observations == nullptr || out_calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (!valid_display(display)) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (observation_count < 3) {
        return GAZE_ERROR_NOT_ENOUGH_DATA;
    }

    std::vector<Observation> packed;
    packed.reserve(observation_count);
    for (size_t index = 0; index < observation_count; ++index) {
        if (!valid_uv(observations[index].u, observations[index].v)) {
            return GAZE_ERROR_INVALID_ARGUMENT;
        }
        packed.push_back(Observation{
            Vec2{observations[index].u, observations[index].v},
            observations[index].sample,
        });
    }

    State state = load_state_from_calibration(*base_calibration);
    const DistancePrior refit_prior = compute_distance_prior(packed);
    if (!gauss_newton_optimize(packed, *display, &state, false, 0.0f, refit_prior)) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }
    gaze_calibration_t calibration = *base_calibration;
    fill_calibration(state, *display, SolveStats{}, static_cast<uint32_t>(observation_count), &calibration);
    const SolveStats stats = compute_solve_stats(packed, calibration, *display);
    fill_calibration(state, *display, stats, static_cast<uint32_t>(observation_count), &calibration);
    // Quick-refit only adjusts pose; preserve the face-frame correction and
    // residual map from the baseline calibration.
    calibration.no_glasses = base_calibration->no_glasses;
    calibration.glasses = base_calibration->glasses;
    calibration.has_glasses = base_calibration->has_glasses;
    calibration.active_state = base_calibration->active_state;
    std::copy(
        std::begin(base_calibration->residual_u),
        std::end(base_calibration->residual_u),
        std::begin(calibration.residual_u)
    );
    std::copy(
        std::begin(base_calibration->residual_v),
        std::end(base_calibration->residual_v),
        std::begin(calibration.residual_v)
    );
    *out_calibration = calibration;
    return GAZE_OK;
}

size_t gaze_calibration_blob_size(void) {
    // version, screen_w, screen_h, T[16], no_glasses[6], glasses[6],
    // residual_u[6], residual_v[6], rmse, median = 45 floats.
    // has_glasses, active_state, sample_count = 3 u32s.
    constexpr size_t kFloatFieldCount = 45u;
    constexpr size_t kU32FieldCount = 3u;
    return 4u + 4u + (kFloatFieldCount * sizeof(float)) + (kU32FieldCount * sizeof(uint32_t));
}

void write_tangent_affine(uint8_t* bytes, size_t& offset, const gaze_tangent_affine_t& t) {
    write_f32_le(bytes, offset, t.G_yy); offset += 4u;
    write_f32_le(bytes, offset, t.G_yp); offset += 4u;
    write_f32_le(bytes, offset, t.G_py); offset += 4u;
    write_f32_le(bytes, offset, t.G_pp); offset += 4u;
    write_f32_le(bytes, offset, t.b_yaw); offset += 4u;
    write_f32_le(bytes, offset, t.b_pitch); offset += 4u;
}

gaze_tangent_affine_t read_tangent_affine(const uint8_t* bytes, size_t& offset) {
    gaze_tangent_affine_t t{};
    t.G_yy = read_f32_le(bytes, offset); offset += 4u;
    t.G_yp = read_f32_le(bytes, offset); offset += 4u;
    t.G_py = read_f32_le(bytes, offset); offset += 4u;
    t.G_pp = read_f32_le(bytes, offset); offset += 4u;
    t.b_yaw = read_f32_le(bytes, offset); offset += 4u;
    t.b_pitch = read_f32_le(bytes, offset); offset += 4u;
    return t;
}

int gaze_calibration_serialize(
    const gaze_calibration_t* calibration,
    void* out_buffer,
    size_t buffer_size
) {
    if (calibration == nullptr || out_buffer == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (buffer_size < gaze_calibration_blob_size()) {
        return GAZE_ERROR_BUFFER_TOO_SMALL;
    }

    auto* bytes = static_cast<uint8_t*>(out_buffer);
    std::memcpy(bytes, kCalibrationMagic, sizeof(kCalibrationMagic));
    write_u32_le(bytes, 4u, kCalibrationEncodingVersion);

    size_t offset = 8u;
    write_f32_le(bytes, offset, calibration->version);
    offset += 4u;
    write_f32_le(bytes, offset, calibration->screen_width_mm);
    offset += 4u;
    write_f32_le(bytes, offset, calibration->screen_height_mm);
    offset += 4u;
    for (float value : calibration->T_provider_from_screen) {
        write_f32_le(bytes, offset, value);
        offset += 4u;
    }
    write_tangent_affine(bytes, offset, calibration->no_glasses);
    write_tangent_affine(bytes, offset, calibration->glasses);
    write_u32_le(bytes, offset, calibration->has_glasses);
    offset += 4u;
    write_u32_le(bytes, offset, calibration->active_state);
    offset += 4u;
    for (float value : calibration->residual_u) {
        write_f32_le(bytes, offset, value);
        offset += 4u;
    }
    for (float value : calibration->residual_v) {
        write_f32_le(bytes, offset, value);
        offset += 4u;
    }
    write_f32_le(bytes, offset, calibration->rmse_px);
    offset += 4u;
    write_f32_le(bytes, offset, calibration->median_err_px);
    offset += 4u;
    write_u32_le(bytes, offset, calibration->sample_count);
    return GAZE_OK;
}

int gaze_calibration_deserialize(
    const void* buffer,
    size_t buffer_size,
    gaze_calibration_t* out_calibration
) {
    if (buffer == nullptr || out_calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (buffer_size < gaze_calibration_blob_size()) {
        return GAZE_ERROR_BAD_ENCODING;
    }

    const auto* bytes = static_cast<const uint8_t*>(buffer);
    if (std::memcmp(bytes, kCalibrationMagic, sizeof(kCalibrationMagic)) != 0) {
        return GAZE_ERROR_BAD_ENCODING;
    }
    if (read_u32_le(bytes, 4u) != kCalibrationEncodingVersion) {
        return GAZE_ERROR_BAD_ENCODING;
    }

    gaze_calibration_t calibration{};
    size_t offset = 8u;
    calibration.version = read_f32_le(bytes, offset);
    offset += 4u;
    calibration.screen_width_mm = read_f32_le(bytes, offset);
    offset += 4u;
    calibration.screen_height_mm = read_f32_le(bytes, offset);
    offset += 4u;
    for (float& value : calibration.T_provider_from_screen) {
        value = read_f32_le(bytes, offset);
        offset += 4u;
    }
    calibration.no_glasses = read_tangent_affine(bytes, offset);
    calibration.glasses = read_tangent_affine(bytes, offset);
    calibration.has_glasses = read_u32_le(bytes, offset);
    offset += 4u;
    calibration.active_state = read_u32_le(bytes, offset);
    offset += 4u;
    for (float& value : calibration.residual_u) {
        value = read_f32_le(bytes, offset);
        offset += 4u;
    }
    for (float& value : calibration.residual_v) {
        value = read_f32_le(bytes, offset);
        offset += 4u;
    }
    calibration.rmse_px = read_f32_le(bytes, offset);
    offset += 4u;
    calibration.median_err_px = read_f32_le(bytes, offset);
    offset += 4u;
    calibration.sample_count = read_u32_le(bytes, offset);
    *out_calibration = calibration;
    return GAZE_OK;
}
