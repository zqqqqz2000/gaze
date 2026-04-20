#include "gaze/gaze_sdk.h"

#include <algorithm>
#include <array>
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
constexpr float kFiniteDifferenceEps = 1e-4f;
constexpr float kPlaneParallelEps = 1e-5f;

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

struct State {
    Mat3 rotation;
    Vec3 center;
    float yaw_bias = 0.0f;
    float pitch_bias = 0.0f;
};

struct Observation {
    Vec2 target_uv;
    gaze_provider_sample_t sample{};
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

Mat3 rotation_x(float angle) {
    const float c = std::cos(angle);
    const float s = std::sin(angle);
    return Mat3{
        Vec3{1.0f, 0.0f, 0.0f},
        Vec3{0.0f, c, s},
        Vec3{0.0f, -s, c},
    };
}

Mat3 rotation_y(float angle) {
    const float c = std::cos(angle);
    const float s = std::sin(angle);
    return Mat3{
        Vec3{c, 0.0f, -s},
        Vec3{0.0f, 1.0f, 0.0f},
        Vec3{s, 0.0f, c},
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

Mat3 build_basis_from_normal(Vec3 z_axis) {
    z_axis = normalized(z_axis);
    Vec3 up{0.0f, 1.0f, 0.0f};
    Vec3 x_axis = cross(up, z_axis);
    if (norm(x_axis) < 1e-4f) {
        up = Vec3{0.0f, 0.0f, 1.0f};
        x_axis = cross(up, z_axis);
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

Vec3 bias_correct_direction(const Vec3& direction, float yaw_bias, float pitch_bias) {
    return normalized(mul(mul(rotation_y(yaw_bias), rotation_x(pitch_bias)), normalized(direction)));
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
    *out_distance = std::fabs(dot(normal, *out_hit - center));
    const float cosine = clamp01(std::fabs(dot(normalized(direction), normal)));
    *out_angle = std::asin(cosine);
    return true;
}

std::vector<float> build_residuals(
    const std::vector<Observation>& observations,
    const gaze_display_desc_t& display,
    const State& state
) {
    std::vector<float> residuals;
    residuals.reserve(observations.size() * 3);
    for (const Observation& observation : observations) {
        const Vec3 origin = make_vec3(observation.sample.gaze_origin_p_m);
        const Vec3 raw_dir = make_vec3(observation.sample.gaze_dir_p);
        const Vec3 corrected_dir = bias_correct_direction(raw_dir, state.yaw_bias, state.pitch_bias);
        const Vec3 target = screen_point_to_provider(display, state.rotation, state.center, observation.target_uv);
        const Vec3 expected_dir = normalized(target - origin);
        const float weight = std::max(0.2f, observation.sample.confidence);
        const Vec3 delta = (corrected_dir - expected_dir) * weight;
        residuals.push_back(delta.x);
        residuals.push_back(delta.y);
        residuals.push_back(delta.z);
    }
    return residuals;
}

State apply_delta(const State& state, const std::vector<float>& delta, bool include_bias) {
    State next = state;
    next.center = next.center + Vec3{delta[0], delta[1], delta[2]};
    const Mat3 delta_rotation = rotation_from_axis_angle(Vec3{delta[3], delta[4], delta[5]});
    next.rotation = mul(delta_rotation, next.rotation);
    if (include_bias) {
        next.yaw_bias += delta[6];
        next.pitch_bias += delta[7];
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
    bool optimize_bias
) {
    const int parameter_count = optimize_bias ? 8 : 6;
    if (observations.size() < 4) {
        return false;
    }

    float damping = 1e-3f;
    for (int iteration = 0; iteration < 30; ++iteration) {
        const std::vector<float> residuals = build_residuals(observations, display, *state);
        const std::size_t residual_count = residuals.size();

        std::vector<float> jacobian(residual_count * static_cast<std::size_t>(parameter_count), 0.0f);
        for (int param = 0; param < parameter_count; ++param) {
            std::vector<float> delta(parameter_count, 0.0f);
            delta[param] = kFiniteDifferenceEps;
            const State plus_state = apply_delta(*state, delta, optimize_bias);
            const std::vector<float> plus_residuals = build_residuals(observations, display, plus_state);
            for (std::size_t row = 0; row < residual_count; ++row) {
                jacobian[row * static_cast<std::size_t>(parameter_count) + static_cast<std::size_t>(param)] =
                    (plus_residuals[row] - residuals[row]) / kFiniteDifferenceEps;
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
        for (int i = 0; i < parameter_count; ++i) {
            jt_j[static_cast<std::size_t>(i * parameter_count + i)] += damping;
            jt_r[static_cast<std::size_t>(i)] = -jt_r[static_cast<std::size_t>(i)];
        }

        std::vector<float> step;
        if (!solve_linear_system(jt_j, jt_r, parameter_count, &step)) {
            return false;
        }

        float step_norm = 0.0f;
        for (float value : step) {
            step_norm += value * value;
        }
        step_norm = std::sqrt(step_norm);
        if (step_norm < 1e-6f) {
            return true;
        }

        const State candidate = apply_delta(*state, step, optimize_bias);
        const std::vector<float> candidate_residuals = build_residuals(observations, display, candidate);

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

Vec3 estimate_ray_bundle_intersection(const std::vector<Observation>& observations, Vec2 center_uv) {
    std::array<float, 9> a{0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    std::array<float, 3> b{0.0f, 0.0f, 0.0f};
    int count = 0;
    for (const Observation& observation : observations) {
        const float du = std::fabs(observation.target_uv.x - center_uv.x);
        const float dv = std::fabs(observation.target_uv.y - center_uv.y);
        if (du > 0.06f || dv > 0.06f) {
            continue;
        }
        const Vec3 origin = make_vec3(observation.sample.gaze_origin_p_m);
        const Vec3 d = normalized(make_vec3(observation.sample.gaze_dir_p));
        const float m00 = 1.0f - d.x * d.x;
        const float m01 = -d.x * d.y;
        const float m02 = -d.x * d.z;
        const float m11 = 1.0f - d.y * d.y;
        const float m12 = -d.y * d.z;
        const float m22 = 1.0f - d.z * d.z;

        a[0] += m00;
        a[1] += m01;
        a[2] += m02;
        a[3] += m01;
        a[4] += m11;
        a[5] += m12;
        a[6] += m02;
        a[7] += m12;
        a[8] += m22;

        b[0] += m00 * origin.x + m01 * origin.y + m02 * origin.z;
        b[1] += m01 * origin.x + m11 * origin.y + m12 * origin.z;
        b[2] += m02 * origin.x + m12 * origin.y + m22 * origin.z;
        ++count;
    }

    if (count < 2) {
        Vec3 avg_origin{0.0f, 0.0f, 0.0f};
        Vec3 avg_dir{0.0f, 0.0f, 0.0f};
        for (const Observation& observation : observations) {
            avg_origin = avg_origin + make_vec3(observation.sample.gaze_origin_p_m);
            avg_dir = avg_dir + normalized(make_vec3(observation.sample.gaze_dir_p));
        }
        avg_origin = avg_origin / static_cast<float>(observations.size());
        avg_dir = normalized(avg_dir);
        return avg_origin + avg_dir * 0.6f;
    }

    std::vector<float> matrix(a.begin(), a.end());
    std::vector<float> rhs(b.begin(), b.end());
    std::vector<float> solution;
    if (!solve_linear_system(matrix, rhs, 3, &solution)) {
        return Vec3{0.0f, 0.0f, 0.6f};
    }
    return Vec3{solution[0], solution[1], solution[2]};
}

State initialize_state(const std::vector<Observation>& observations, const gaze_display_desc_t& display) {
    (void)display;
    const Vec2 center_uv{0.5f, 0.5f};
    const Vec3 center = estimate_ray_bundle_intersection(observations, center_uv);
    Vec3 avg_dir{0.0f, 0.0f, 0.0f};
    int count = 0;
    for (const Observation& observation : observations) {
        const float du = std::fabs(observation.target_uv.x - center_uv.x);
        const float dv = std::fabs(observation.target_uv.y - center_uv.y);
        if (du <= 0.06f && dv <= 0.06f) {
            avg_dir = avg_dir + normalized(make_vec3(observation.sample.gaze_dir_p));
            ++count;
        }
    }
    if (count == 0) {
        for (const Observation& observation : observations) {
            avg_dir = avg_dir + normalized(make_vec3(observation.sample.gaze_dir_p));
            ++count;
        }
    }
    avg_dir = normalized(avg_dir / static_cast<float>(std::max(1, count)));
    State state;
    state.center = center;
    state.rotation = build_basis_from_normal(-1.0f * avg_dir);
    return state;
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
        calibration.yaw_bias_rad,
        calibration.pitch_bias_rad,
    };
}

void fill_calibration(
    const State& state,
    const gaze_display_desc_t& display,
    const SolveStats& stats,
    uint32_t sample_count,
    gaze_calibration_t* out_calibration
) {
    out_calibration->version = 1.0f;
    out_calibration->screen_width_mm = display.screen_width_mm;
    out_calibration->screen_height_mm = display.screen_height_mm;
    store_transform(state, out_calibration->T_provider_from_screen);
    out_calibration->yaw_bias_rad = state.yaw_bias;
    out_calibration->pitch_bias_rad = state.pitch_bias;
    out_calibration->yaw_gain = 1.0f;
    out_calibration->pitch_gain = 1.0f;
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

}  // namespace

struct gaze_cal_session {
    gaze_display_desc_t display{};
    gaze_cal_mode_t mode = GAZE_CAL_MODE_FULL;
    std::unordered_map<uint32_t, Vec2> targets;
    std::vector<Observation> observations;
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

int gaze_cal_solve(gaze_cal_session_t* session, gaze_calibration_t* out_calibration) {
    if (session == nullptr || out_calibration == nullptr) {
        return GAZE_ERROR_INVALID_ARGUMENT;
    }
    if (session->observations.size() < 6) {
        return GAZE_ERROR_NOT_ENOUGH_DATA;
    }
    State state = initialize_state(session->observations, session->display);
    if (!gauss_newton_optimize(session->observations, session->display, &state, true)) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }
    gaze_calibration_t calibration{};
    fill_calibration(state, session->display, SolveStats{}, static_cast<uint32_t>(session->observations.size()), &calibration);
    const SolveStats stats = compute_solve_stats(session->observations, calibration, session->display);
    fill_calibration(state, session->display, stats, static_cast<uint32_t>(session->observations.size()), &calibration);
    *out_calibration = calibration;
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
    const Vec3 direction = bias_correct_direction(
        raw_dir,
        calibration->yaw_bias_rad * calibration->yaw_gain,
        calibration->pitch_bias_rad * calibration->pitch_gain
    );

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
    if (!gauss_newton_optimize(packed, *display, &state, false)) {
        return GAZE_ERROR_NUMERIC_FAILURE;
    }
    gaze_calibration_t calibration = *base_calibration;
    fill_calibration(state, *display, SolveStats{}, static_cast<uint32_t>(observation_count), &calibration);
    const SolveStats stats = compute_solve_stats(packed, calibration, *display);
    fill_calibration(state, *display, stats, static_cast<uint32_t>(observation_count), &calibration);
    calibration.yaw_bias_rad = base_calibration->yaw_bias_rad;
    calibration.pitch_bias_rad = base_calibration->pitch_bias_rad;
    calibration.yaw_gain = base_calibration->yaw_gain;
    calibration.pitch_gain = base_calibration->pitch_gain;
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
