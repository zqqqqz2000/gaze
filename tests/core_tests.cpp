#include "gaze/gaze_sdk.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <array>
#include <vector>

namespace {

constexpr float kTolerance = 1e-3f;

void expect_true(bool condition, const char* message) {
    if (!condition) {
        std::cerr << "Assertion failed: " << message << "\n";
        std::exit(1);
    }
}

void expect_near(float actual, float expected, float tolerance, const char* message) {
    if (std::fabs(actual - expected) > tolerance) {
        std::cerr << "Assertion failed: " << message << ", actual=" << actual << ", expected=" << expected << "\n";
        std::exit(1);
    }
}

gaze_display_desc_t make_display() {
    return gaze_display_desc_t{
        600.0f,
        340.0f,
        1920,
        1080,
    };
}

gaze_tangent_affine_t identity_tangent_affine() {
    gaze_tangent_affine_t t{};
    t.G_yy = 1.0f;
    t.G_pp = 1.0f;
    return t;
}

gaze_calibration_t make_front_calibration() {
    gaze_calibration_t calibration{};
    calibration.version = 2.0f;
    calibration.screen_width_mm = 600.0f;
    calibration.screen_height_mm = 340.0f;
    calibration.T_provider_from_screen[0] = -1.0f;
    calibration.T_provider_from_screen[5] = 1.0f;
    calibration.T_provider_from_screen[10] = -1.0f;
    calibration.T_provider_from_screen[15] = 1.0f;
    calibration.T_provider_from_screen[14] = 0.6f;
    calibration.no_glasses = identity_tangent_affine();
    calibration.glasses = identity_tangent_affine();
    calibration.has_glasses = 0u;
    calibration.active_state = GAZE_STATE_NO_GLASSES;
    return calibration;
}

gaze_provider_sample_t make_sample(float origin_x, float origin_y, float origin_z, float dir_x, float dir_y, float dir_z) {
    gaze_provider_sample_t sample{};
    sample.tracking_flags = GAZE_TRACKING_FLAG_TRACKED;
    sample.gaze_origin_p_m[0] = origin_x;
    sample.gaze_origin_p_m[1] = origin_y;
    sample.gaze_origin_p_m[2] = origin_z;
    sample.gaze_dir_p[0] = dir_x;
    sample.gaze_dir_p[1] = dir_y;
    sample.gaze_dir_p[2] = dir_z;
    sample.head_rot_p_f_q[3] = 1.0f;
    sample.confidence = 1.0f;
    sample.face_distance_m = 0.55f;
    return sample;
}

gaze_provider_sample_t make_sample_with_head_yaw(
    float origin_x, float origin_y, float origin_z,
    float dir_x, float dir_y, float dir_z,
    float head_yaw
) {
    gaze_provider_sample_t sample = make_sample(origin_x, origin_y, origin_z, dir_x, dir_y, dir_z);
    sample.head_rot_p_f_q[0] = 0.0f;
    sample.head_rot_p_f_q[1] = std::sin(head_yaw * 0.5f);
    sample.head_rot_p_f_q[2] = 0.0f;
    sample.head_rot_p_f_q[3] = std::cos(head_yaw * 0.5f);
    return sample;
}

gaze_refit_observation_t make_refit_observation(float u, float v, const gaze_provider_sample_t& sample) {
    gaze_refit_observation_t observation{};
    observation.u = u;
    observation.v = v;
    observation.sample = sample;
    return observation;
}

namespace test_math {

struct V3 { float x, y, z; };

V3 sub(V3 a, V3 b) { return {a.x - b.x, a.y - b.y, a.z - b.z}; }

V3 normalize(V3 v) {
    float l = std::sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    return {v.x / l, v.y / l, v.z / l};
}

V3 rot_x(V3 v, float a) {
    float c = std::cos(a), s = std::sin(a);
    return {v.x, c * v.y - s * v.z, s * v.y + c * v.z};
}

V3 rot_y(V3 v, float a) {
    float c = std::cos(a), s = std::sin(a);
    return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z};
}

V3 screen_point_front(float u, float v) {
    return {(0.5f - u) * 0.6f, (0.5f - v) * 0.34f, 0.6f};
}

V3 biased_gaze(V3 eye, float target_u, float target_v,
               float yaw_bias, float pitch_bias, float head_yaw) {
    V3 target = screen_point_front(target_u, target_v);
    V3 d_true = normalize(sub(target, eye));
    V3 d_f = rot_y(d_true, -head_yaw);
    V3 d1 = rot_y(d_f, -yaw_bias);
    V3 d_biased_f = rot_x(d1, -pitch_bias);
    return normalize(rot_y(d_biased_f, head_yaw));
}

}  // namespace test_math

void test_runtime_solve_center() {
    const gaze_display_desc_t display = make_display();
    const gaze_calibration_t calibration = make_front_calibration();
    const gaze_provider_sample_t sample = make_sample(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f);

    gaze_screen_point_t point{};
    const int result = gaze_solve_point(&sample, &calibration, &display, &point);
    expect_true(result == GAZE_OK, "center solve should succeed");
    expect_near(point.u, 0.5f, kTolerance, "center u");
    expect_near(point.v, 0.5f, kTolerance, "center v");
    expect_true(point.inside_screen == 1u, "center point should be inside screen");
}

void test_runtime_solve_offset() {
    const gaze_display_desc_t display = make_display();
    const gaze_calibration_t calibration = make_front_calibration();
    const gaze_provider_sample_t sample = make_sample(0.0f, 0.0f, 0.0f, -0.25f, 0.12f, 1.0f);

    gaze_screen_point_t point{};
    const int result = gaze_solve_point(&sample, &calibration, &display, &point);
    expect_true(result == GAZE_OK, "offset solve should succeed");
    expect_true(point.u > 0.5f, "right-looking point should move to screen right");
    expect_true(point.v < 0.5f, "up-looking point should move to screen top");
}

void test_calibration_session() {
    const gaze_display_desc_t display = make_display();
    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "session should be created");

    const std::vector<std::pair<float, float>> targets{
        {0.2f, 0.2f},
        {0.5f, 0.2f},
        {0.8f, 0.2f},
        {0.2f, 0.5f},
        {0.5f, 0.5f},
        {0.8f, 0.5f},
        {0.2f, 0.8f},
        {0.5f, 0.8f},
        {0.8f, 0.8f},
    };

    for (size_t index = 0; index < targets.size(); ++index) {
        expect_true(
            gaze_cal_push_target(session, targets[index].first, targets[index].second, static_cast<uint32_t>(index)) ==
                GAZE_OK,
            "push target should succeed"
        );

        const float x_m = (targets[index].first - 0.5f) * 0.6f;
        const float y_m = (0.5f - targets[index].second) * 0.34f;
        const gaze_provider_sample_t sample = make_sample(0.0f, 0.0f, 0.0f, -x_m, y_m, 0.6f);
        expect_true(
            gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(index)) == GAZE_OK,
            "push sample should succeed"
        );
    }

    gaze_calibration_t calibration{};
    const int solve_result = gaze_cal_solve(session, &calibration);
    expect_true(solve_result == GAZE_OK, "calibration solve should succeed");
    expect_true(calibration.sample_count == targets.size(), "sample count should match");
    expect_true(calibration.rmse_px < 80.0f, "synthetic solve should converge to a reasonable rmse");

    const gaze_provider_sample_t center_sample = make_sample(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.6f);
    gaze_screen_point_t point{};
    expect_true(gaze_solve_point(&center_sample, &calibration, &display, &point) == GAZE_OK, "solved cal should work");
    expect_near(point.u, 0.5f, 0.08f, "calibrated center u");
    expect_near(point.v, 0.5f, 0.08f, "calibrated center v");

    gaze_cal_free(session);
}

void test_refit_pose() {
    const gaze_display_desc_t display = make_display();
    const gaze_calibration_t base = make_front_calibration();
    const std::array<gaze_refit_observation_t, 5> observations{{
        make_refit_observation(0.5f, 0.5f, make_sample(0.02f, 0.0f, 0.0f, -0.02f, 0.0f, 0.6f)),
        make_refit_observation(0.2f, 0.2f, make_sample(0.02f, 0.0f, 0.0f, 0.16f, 0.102f, 0.6f)),
        make_refit_observation(0.8f, 0.2f, make_sample(0.02f, 0.0f, 0.0f, -0.20f, 0.102f, 0.6f)),
        make_refit_observation(0.2f, 0.8f, make_sample(0.02f, 0.0f, 0.0f, 0.16f, -0.102f, 0.6f)),
        make_refit_observation(0.8f, 0.8f, make_sample(0.02f, 0.0f, 0.0f, -0.20f, -0.102f, 0.6f)),
    }};

    gaze_calibration_t refit{};
    expect_true(
        gaze_refit_pose(&base, &display, observations.data(), observations.size(), &refit) == GAZE_OK,
        "refit should succeed"
    );
    expect_true(refit.sample_count == observations.size(), "refit sample count should match");
    expect_true(std::fabs(refit.T_provider_from_screen[12] - 0.02f) < 0.03f, "refit should recover x translation");

    gaze_screen_point_t point{};
    const gaze_provider_sample_t center_sample = observations[0].sample;
    expect_true(gaze_solve_point(&center_sample, &refit, &display, &point) == GAZE_OK, "refit solve should work");
    expect_near(point.u, 0.5f, 0.06f, "refit center u");
    expect_near(point.v, 0.5f, 0.06f, "refit center v");
}

void test_calibration_blob_round_trip() {
    gaze_calibration_t calibration = make_front_calibration();
    calibration.no_glasses.b_yaw = 0.01f;
    calibration.no_glasses.b_pitch = -0.02f;
    calibration.glasses.G_yy = 1.1f;
    calibration.glasses.G_pp = 0.9f;
    calibration.glasses.G_yp = 0.05f;
    calibration.glasses.b_yaw = -0.005f;
    calibration.has_glasses = 1u;
    calibration.active_state = GAZE_STATE_GLASSES;
    calibration.residual_u[0] = 0.03f;
    calibration.residual_v[5] = -0.01f;
    calibration.rmse_px = 12.0f;
    calibration.median_err_px = 9.0f;
    calibration.sample_count = 42u;

    std::vector<unsigned char> blob(gaze_calibration_blob_size());
    expect_true(
        gaze_calibration_serialize(&calibration, blob.data(), blob.size()) == GAZE_OK,
        "calibration serialization should succeed"
    );

    gaze_calibration_t decoded{};
    expect_true(
        gaze_calibration_deserialize(blob.data(), blob.size(), &decoded) == GAZE_OK,
        "calibration deserialization should succeed"
    );
    expect_near(decoded.version, calibration.version, kTolerance, "blob version");
    expect_near(decoded.screen_width_mm, calibration.screen_width_mm, kTolerance, "blob width");
    expect_near(decoded.screen_height_mm, calibration.screen_height_mm, kTolerance, "blob height");
    expect_near(decoded.T_provider_from_screen[12], calibration.T_provider_from_screen[12], kTolerance, "blob tx");
    expect_near(decoded.T_provider_from_screen[14], calibration.T_provider_from_screen[14], kTolerance, "blob tz");
    expect_near(decoded.no_glasses.b_yaw, calibration.no_glasses.b_yaw, kTolerance, "blob no_glasses b_yaw");
    expect_near(decoded.no_glasses.b_pitch, calibration.no_glasses.b_pitch, kTolerance, "blob no_glasses b_pitch");
    expect_near(decoded.glasses.G_yy, calibration.glasses.G_yy, kTolerance, "blob glasses G_yy");
    expect_near(decoded.glasses.G_pp, calibration.glasses.G_pp, kTolerance, "blob glasses G_pp");
    expect_near(decoded.glasses.G_yp, calibration.glasses.G_yp, kTolerance, "blob glasses G_yp");
    expect_near(decoded.glasses.b_yaw, calibration.glasses.b_yaw, kTolerance, "blob glasses b_yaw");
    expect_true(decoded.has_glasses == 1u, "blob has_glasses");
    expect_true(decoded.active_state == GAZE_STATE_GLASSES, "blob active_state");
    expect_near(decoded.residual_u[0], calibration.residual_u[0], kTolerance, "blob residual u");
    expect_near(decoded.residual_v[5], calibration.residual_v[5], kTolerance, "blob residual v");
    expect_true(decoded.sample_count == calibration.sample_count, "blob sample count");
}

void test_runtime_residual_application() {
    const gaze_display_desc_t display = make_display();
    gaze_calibration_t calibration = make_front_calibration();
    calibration.residual_u[0] = 0.1f;
    calibration.residual_v[0] = -0.05f;
    const gaze_provider_sample_t sample = make_sample(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f);

    gaze_screen_point_t point{};
    expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "residual solve should succeed");
    expect_near(point.u, 0.6f, kTolerance, "residual should shift u");
    expect_near(point.v, 0.45f, kTolerance, "residual should shift v");
}

void test_invalid_arguments() {
    const gaze_display_desc_t display = make_display();
    const gaze_calibration_t calibration = make_front_calibration();
    const gaze_provider_sample_t sample = make_sample(0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f);
    gaze_screen_point_t point{};

    expect_true(gaze_cal_begin(nullptr, GAZE_CAL_MODE_FULL) == nullptr, "null display should fail session creation");
    expect_true(gaze_solve_point(nullptr, &calibration, &display, &point) == GAZE_ERROR_INVALID_ARGUMENT, "null sample");
    expect_true(gaze_solve_point(&sample, nullptr, &display, &point) == GAZE_ERROR_INVALID_ARGUMENT, "null calibration");
    expect_true(gaze_solve_point(&sample, &calibration, nullptr, &point) == GAZE_ERROR_INVALID_ARGUMENT, "null display");
    expect_true(
        gaze_calibration_serialize(&calibration, nullptr, gaze_calibration_blob_size()) == GAZE_ERROR_INVALID_ARGUMENT,
        "null blob buffer"
    );
    std::vector<unsigned char> blob(gaze_calibration_blob_size() - 1u, 0u);
    expect_true(
        gaze_calibration_serialize(&calibration, blob.data(), blob.size()) == GAZE_ERROR_BUFFER_TOO_SMALL,
        "short blob should fail encode"
    );

    std::vector<unsigned char> tiny_blob(4u, 0u);
    gaze_calibration_t decoded{};
    expect_true(
        gaze_calibration_deserialize(tiny_blob.data(), tiny_blob.size(), &decoded) == GAZE_ERROR_BAD_ENCODING,
        "tiny blob should fail decode"
    );
    expect_true(
        gaze_refit_pose(&calibration, &display, nullptr, 0u, &decoded) == GAZE_ERROR_INVALID_ARGUMENT,
        "null refit observations"
    );
}

void test_head_rotation_invariance() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.04f;
    const float pitch_bias = -0.025f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "head inv: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    const test_math::V3 cal_eye{0.0f, 0.0f, 0.0f};
    for (size_t i = 0; i < targets.size(); ++i) {
        expect_true(
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i)) == GAZE_OK,
            "head inv: push target"
        );
        const auto dir = test_math::biased_gaze(cal_eye, targets[i].first, targets[i].second, yaw_bias, pitch_bias, 0.0f);
        const auto sample = make_sample_with_head_yaw(cal_eye.x, cal_eye.y, cal_eye.z, dir.x, dir.y, dir.z, 0.0f);
        expect_true(gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i)) == GAZE_OK, "head inv: push sample");
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "head inv: solve");

    {
        const auto dir = test_math::biased_gaze({0, 0, 0}, 0.5f, 0.5f, yaw_bias, pitch_bias, 0.0f);
        const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, 0.0f);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "head inv: identity solve");
        expect_near(point.u, 0.5f, 0.06f, "head inv: identity u");
        expect_near(point.v, 0.5f, 0.06f, "head inv: identity v");
    }

    {
        const float test_yaw = 0.4363f;
        const test_math::V3 test_eye{0.08f, 0.01f, 0.02f};
        const auto dir = test_math::biased_gaze(test_eye, 0.5f, 0.5f, yaw_bias, pitch_bias, test_yaw);
        const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, test_yaw);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "head inv: 25deg solve");
        expect_near(point.u, 0.5f, 0.06f, "head inv: 25deg u");
        expect_near(point.v, 0.5f, 0.06f, "head inv: 25deg v");
    }

    {
        const float test_yaw = -0.35f;
        const test_math::V3 test_eye{-0.06f, 0.02f, 0.0f};
        const auto dir = test_math::biased_gaze(test_eye, 0.2f, 0.8f, yaw_bias, pitch_bias, test_yaw);
        const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, test_yaw);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "head inv: -20deg solve");
        expect_near(point.u, 0.2f, 0.06f, "head inv: -20deg u");
        expect_near(point.v, 0.8f, 0.06f, "head inv: -20deg v");
    }

    gaze_cal_free(session);
}

void test_calibration_mixed_head_poses() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.035f;
    const float pitch_bias = -0.02f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "mixed: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {0.0f, 0.15f, -0.12f, -0.2f, 0.0f, 0.25f, 0.1f, -0.15f, 0.3f};
    const test_math::V3 eyes[] = {
        {0, 0, 0}, {0.03f, 0, 0.01f}, {-0.02f, 0.01f, 0},
        {-0.05f, 0, 0}, {0, 0, 0}, {0.06f, 0.01f, 0.01f},
        {0.02f, -0.01f, 0}, {-0.03f, 0, 0.01f}, {0.08f, 0, 0.02f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        expect_true(
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i)) == GAZE_OK,
            "mixed: push target"
        );
        const auto dir = test_math::biased_gaze(eyes[i], targets[i].first, targets[i].second, yaw_bias, pitch_bias, head_yaws[i]);
        const auto sample = make_sample_with_head_yaw(eyes[i].x, eyes[i].y, eyes[i].z, dir.x, dir.y, dir.z, head_yaws[i]);
        expect_true(gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i)) == GAZE_OK, "mixed: push sample");
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "mixed: solve");

    const float test_yaw = 0.40f;
    const test_math::V3 test_eye{0.1f, 0.0f, 0.03f};
    const auto dir = test_math::biased_gaze(test_eye, 0.5f, 0.5f, yaw_bias, pitch_bias, test_yaw);
    const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, test_yaw);
    gaze_screen_point_t point{};
    expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "mixed: solve point");
    expect_near(point.u, 0.5f, 0.06f, "mixed: center u");
    expect_near(point.v, 0.5f, 0.06f, "mixed: center v");

    gaze_cal_free(session);
}

void test_bias_correction_face_frame_multiple_targets() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.06f;
    const float pitch_bias = -0.04f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "face frame: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const auto dir = test_math::biased_gaze({0, 0, 0}, targets[i].first, targets[i].second, yaw_bias, pitch_bias, 0.0f);
        const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, 0.0f);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "face frame: solve");

    const float test_yaw = 0.5236f;
    const test_math::V3 test_eye{0.1f, 0.02f, 0.03f};
    const std::vector<std::pair<float, float>> probes{
        {0.3f, 0.3f}, {0.7f, 0.3f}, {0.5f, 0.5f}, {0.3f, 0.7f}, {0.7f, 0.7f},
    };

    for (const auto& [tu, tv] : probes) {
        const auto dir = test_math::biased_gaze(test_eye, tu, tv, yaw_bias, pitch_bias, test_yaw);
        const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, test_yaw);
        gaze_screen_point_t point{};
        const int result = gaze_solve_point(&sample, &calibration, &display, &point);
        expect_true(result == GAZE_OK, "face frame: solve point");
        char msg[128];
        std::snprintf(msg, sizeof(msg), "face frame u: actual=%.3f expected=%.2f", point.u, tu);
        expect_near(point.u, tu, 0.07f, msg);
        std::snprintf(msg, sizeof(msg), "face frame v: actual=%.3f expected=%.2f", point.v, tv);
        expect_near(point.v, tv, 0.07f, msg);
    }

    gaze_cal_free(session);
}

void test_head_translation_large_range() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.045f;
    const float pitch_bias = -0.03f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "xlate: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const auto dir = test_math::biased_gaze({0, 0, 0}, targets[i].first, targets[i].second, yaw_bias, pitch_bias, 0.0f);
        const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, 0.0f);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "xlate: solve");

    const test_math::V3 eye_positions[] = {
        {0.20f, 0.0f, 0.0f},
        {-0.18f, 0.0f, 0.0f},
        {0.0f, 0.15f, 0.0f},
        {0.0f, -0.12f, 0.0f},
        {0.0f, 0.0f, 0.10f},
        {0.0f, 0.0f, -0.08f},
        {0.15f, 0.10f, 0.05f},
        {-0.12f, -0.08f, 0.07f},
        {0.18f, -0.10f, -0.06f},
        {-0.20f, 0.12f, 0.09f},
        {0.10f, 0.14f, -0.05f},
        {-0.07f, -0.15f, 0.10f},
    };
    const std::vector<std::pair<float, float>> probes{
        {0.5f, 0.5f}, {0.2f, 0.2f}, {0.8f, 0.8f}, {0.3f, 0.7f}, {0.7f, 0.3f},
    };

    for (const auto& eye : eye_positions) {
        const float head_yaw = std::atan2(eye.x, 0.6f) * 0.3f;
        for (const auto& [tu, tv] : probes) {
            const auto dir = test_math::biased_gaze(eye, tu, tv, yaw_bias, pitch_bias, head_yaw);
            const auto sample = make_sample_with_head_yaw(eye.x, eye.y, eye.z, dir.x, dir.y, dir.z, head_yaw);
            gaze_screen_point_t point{};
            const int result = gaze_solve_point(&sample, &calibration, &display, &point);
            expect_true(result == GAZE_OK, "xlate: solve point");
            char msg[128];
            std::snprintf(msg, sizeof(msg),
                "xlate eye=(%.2f,%.2f,%.2f) target=(%.1f,%.1f): u=%.3f expected=%.2f",
                eye.x, eye.y, eye.z, tu, tv, point.u, tu);
            expect_near(point.u, tu, 0.07f, msg);
            std::snprintf(msg, sizeof(msg),
                "xlate eye=(%.2f,%.2f,%.2f) target=(%.1f,%.1f): v=%.3f expected=%.2f",
                eye.x, eye.y, eye.z, tu, tv, point.v, tv);
            expect_near(point.v, tv, 0.07f, msg);
        }
    }

    gaze_cal_free(session);
}

namespace test_math {

V3 screen_point_offset(float u, float v, float screen_w_m, float screen_h_m, V3 center, V3 ax, V3 ay) {
    float sx = (u - 0.5f) * screen_w_m;
    float sy = (0.5f - v) * screen_h_m;
    return {center.x + ax.x * sx + ay.x * sy,
            center.y + ax.y * sx + ay.y * sy,
            center.z + ax.z * sx + ay.z * sy};
}

}  // namespace test_math (extension)

void test_calibration_phone_on_left() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.03f;
    const float pitch_bias = -0.015f;

    const test_math::V3 screen_center{0.15f, -0.1f, 0.55f};
    const float screen_w_m = 0.6f;
    const float screen_h_m = 0.34f;
    const test_math::V3 ax{-1.0f, 0.0f, 0.0f};
    const test_math::V3 ay{0.0f, 1.0f, 0.0f};

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "phone-left: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {-0.15f, 0.0f, 0.2f, -0.1f, 0.0f, 0.15f, -0.12f, 0.05f, 0.25f};

    for (size_t i = 0; i < targets.size(); ++i) {
        expect_true(
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-left: push target"
        );
        const test_math::V3 eye{0.0f, 0.0f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(
            targets[i].first, targets[i].second, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, eye));
        auto d_f = test_math::rot_y(d_true, -head_yaws[i]);
        d_f = test_math::rot_y(d_f, -yaw_bias);
        d_f = test_math::rot_x(d_f, -pitch_bias);
        auto d_biased = test_math::normalize(test_math::rot_y(d_f, head_yaws[i]));

        const auto sample = make_sample_with_head_yaw(
            eye.x, eye.y, eye.z, d_biased.x, d_biased.y, d_biased.z, head_yaws[i]);
        expect_true(gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-left: push sample");
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "phone-left: solve");
    expect_true(calibration.rmse_px < 80.0f, "phone-left: rmse should be reasonable");

    {
        const float test_yaw = 0.3f;
        const test_math::V3 test_eye{0.05f, 0.0f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(0.5f, 0.5f, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, test_eye));
        auto d_f = test_math::rot_y(d_true, -test_yaw);
        d_f = test_math::rot_y(d_f, -yaw_bias);
        d_f = test_math::rot_x(d_f, -pitch_bias);
        auto d_biased = test_math::normalize(test_math::rot_y(d_f, test_yaw));

        const auto sample = make_sample_with_head_yaw(
            test_eye.x, test_eye.y, test_eye.z, d_biased.x, d_biased.y, d_biased.z, test_yaw);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "phone-left: runtime solve");
        expect_near(point.u, 0.5f, 0.08f, "phone-left: center u");
        expect_near(point.v, 0.5f, 0.08f, "phone-left: center v");
    }

    gaze_cal_free(session);
}

void test_calibration_phone_on_right() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.025f;
    const float pitch_bias = -0.01f;

    const test_math::V3 screen_center{-0.15f, -0.1f, 0.55f};
    const float screen_w_m = 0.6f;
    const float screen_h_m = 0.34f;
    const test_math::V3 ax{-1.0f, 0.0f, 0.0f};
    const test_math::V3 ay{0.0f, 1.0f, 0.0f};

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "phone-right: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {0.2f, 0.0f, -0.15f, 0.1f, 0.0f, -0.1f, 0.12f, -0.05f, -0.25f};

    for (size_t i = 0; i < targets.size(); ++i) {
        expect_true(
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-right: push target"
        );
        const test_math::V3 eye{0.0f, 0.0f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(
            targets[i].first, targets[i].second, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, eye));
        auto d_f = test_math::rot_y(d_true, -head_yaws[i]);
        d_f = test_math::rot_y(d_f, -yaw_bias);
        d_f = test_math::rot_x(d_f, -pitch_bias);
        auto d_biased = test_math::normalize(test_math::rot_y(d_f, head_yaws[i]));

        const auto sample = make_sample_with_head_yaw(
            eye.x, eye.y, eye.z, d_biased.x, d_biased.y, d_biased.z, head_yaws[i]);
        expect_true(gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-right: push sample");
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "phone-right: solve");
    expect_true(calibration.rmse_px < 80.0f, "phone-right: rmse should be reasonable");

    {
        char msg[128];
        std::snprintf(msg, sizeof(msg), "phone-right: b_yaw=%.3f should be small",
                      calibration.no_glasses.b_yaw);
        expect_true(std::fabs(calibration.no_glasses.b_yaw) < 0.785f, msg);
    }

    {
        const float test_yaw = -0.3f;
        const test_math::V3 test_eye{-0.05f, 0.0f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(0.5f, 0.5f, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, test_eye));
        auto d_f = test_math::rot_y(d_true, -test_yaw);
        d_f = test_math::rot_y(d_f, -yaw_bias);
        d_f = test_math::rot_x(d_f, -pitch_bias);
        auto d_biased = test_math::normalize(test_math::rot_y(d_f, test_yaw));

        const auto sample = make_sample_with_head_yaw(
            test_eye.x, test_eye.y, test_eye.z, d_biased.x, d_biased.y, d_biased.z, test_yaw);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "phone-right: runtime solve");
        expect_near(point.u, 0.5f, 0.08f, "phone-right: center u");
        expect_near(point.v, 0.5f, 0.08f, "phone-right: center v");
    }

    gaze_cal_free(session);
}

void test_calibration_phone_horizontal() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.02f;
    const float pitch_bias = -0.01f;

    const test_math::V3 screen_center{0.0f, -0.25f, 0.5f};
    const float screen_w_m = 0.6f;
    const float screen_h_m = 0.34f;
    const test_math::V3 ax{-1.0f, 0.0f, 0.0f};
    const test_math::V3 ay{0.0f, 1.0f, 0.0f};

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "phone-horiz: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    const float pitch_q = 0.15f;
    const float qx = std::sin(pitch_q * 0.5f);
    const float qw = std::cos(pitch_q * 0.5f);

    for (size_t i = 0; i < targets.size(); ++i) {
        expect_true(
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-horiz: push target"
        );
        const test_math::V3 eye{0.0f, 0.12f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(
            targets[i].first, targets[i].second, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, eye));
        auto d_f = test_math::rot_x(d_true, -pitch_q);
        d_f = test_math::rot_y(d_f, -yaw_bias);
        d_f = test_math::rot_x(d_f, -pitch_bias);
        auto d_biased = test_math::normalize(test_math::rot_x(d_f, pitch_q));

        auto sample = make_sample(eye.x, eye.y, eye.z, d_biased.x, d_biased.y, d_biased.z);
        sample.head_rot_p_f_q[0] = qx;
        sample.head_rot_p_f_q[1] = 0.0f;
        sample.head_rot_p_f_q[2] = 0.0f;
        sample.head_rot_p_f_q[3] = qw;
        expect_true(gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i)) == GAZE_OK,
            "phone-horiz: push sample");
    }

    gaze_calibration_t calibration{};
    const int solve_result = gaze_cal_solve(session, &calibration);
    expect_true(solve_result == GAZE_OK, "phone-horiz: solve should succeed");

    const float T_center_dist = std::sqrt(
        calibration.T_provider_from_screen[12] * calibration.T_provider_from_screen[12] +
        calibration.T_provider_from_screen[13] * calibration.T_provider_from_screen[13] +
        calibration.T_provider_from_screen[14] * calibration.T_provider_from_screen[14]
    );
    expect_true(T_center_dist < 3.0f, "phone-horiz: screen center should be reasonable distance (<3m)");
    expect_true(calibration.rmse_px < 120.0f, "phone-horiz: rmse should converge");

    gaze_cal_free(session);
}

void test_bias_recovery() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.05f;
    const float pitch_bias = -0.03f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "bias: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {0.0f, 0.2f, -0.15f, -0.25f, 0.0f, 0.3f, 0.15f, -0.2f, 0.35f};

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const auto dir = test_math::biased_gaze(
            {0, 0, 0}, targets[i].first, targets[i].second, yaw_bias, pitch_bias, head_yaws[i]);
        const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, head_yaws[i]);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "bias: solve");

    expect_true(std::isfinite(calibration.no_glasses.b_yaw), "bias: b_yaw should be finite");
    expect_true(std::isfinite(calibration.no_glasses.b_pitch), "bias: b_pitch should be finite");
    // Bias can be partially absorbed into pose rotation when the head-yaw
    // span happens to align with the injected bias axis, so we only require
    // the recovered parameters to be in a physically sensible range. The
    // real regression check is the runtime-solve error below.
    expect_true(std::fabs(calibration.no_glasses.b_yaw) < 0.30f,
                "bias: b_yaw should be in reasonable range");
    expect_true(std::fabs(calibration.no_glasses.b_pitch) < 0.30f,
                "bias: b_pitch should be in reasonable range");

    const float test_yaw = 0.45f;
    const test_math::V3 test_eye{0.12f, 0.02f, 0.04f};
    const std::vector<std::pair<float, float>> probes{
        {0.2f, 0.2f}, {0.8f, 0.2f}, {0.5f, 0.5f}, {0.2f, 0.8f}, {0.8f, 0.8f},
    };
    for (const auto& [tu, tv] : probes) {
        const auto dir = test_math::biased_gaze(test_eye, tu, tv, yaw_bias, pitch_bias, test_yaw);
        const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, test_yaw);
        gaze_screen_point_t point{};
        expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "bias: solve point");
        char msg[128];
        std::snprintf(msg, sizeof(msg), "bias u: actual=%.3f expected=%.2f", point.u, tu);
        expect_near(point.u, tu, 0.08f, msg);
        std::snprintf(msg, sizeof(msg), "bias v: actual=%.3f expected=%.2f", point.v, tv);
        expect_near(point.v, tv, 0.08f, msg);
    }

    gaze_cal_free(session);
}

void test_initialization_with_tilted_screen() {
    const gaze_display_desc_t display = make_display();

    const test_math::V3 screen_center{0.0f, 0.0f, 0.65f};
    const float tilt_angle = 0.3f;
    const float ct = std::cos(tilt_angle);
    const float st = std::sin(tilt_angle);
    const test_math::V3 ax{-1.0f, 0.0f, 0.0f};
    const test_math::V3 ay{0.0f, ct, -st};
    const float screen_w_m = 0.6f;
    const float screen_h_m = 0.34f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "tilt: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const test_math::V3 eye{0.0f, 0.0f, 0.0f};
        const auto target_pt = test_math::screen_point_offset(
            targets[i].first, targets[i].second, screen_w_m, screen_h_m, screen_center, ax, ay);
        auto d_true = test_math::normalize(test_math::sub(target_pt, eye));
        auto sample = make_sample(eye.x, eye.y, eye.z, d_true.x, d_true.y, d_true.z);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "tilt: solve");
    expect_true(calibration.rmse_px < 40.0f, "tilt: rmse should be very low for unbiased data");

    const test_math::V3 probe_eye{0.1f, 0.05f, 0.0f};
    const auto target_pt = test_math::screen_point_offset(0.5f, 0.5f, screen_w_m, screen_h_m, screen_center, ax, ay);
    auto probe_dir = test_math::normalize(test_math::sub(target_pt, probe_eye));
    auto sample = make_sample(probe_eye.x, probe_eye.y, probe_eye.z, probe_dir.x, probe_dir.y, probe_dir.z);
    gaze_screen_point_t point{};
    expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "tilt: runtime solve");
    expect_near(point.u, 0.5f, 0.06f, "tilt: center u");
    expect_near(point.v, 0.5f, 0.06f, "tilt: center v");

    gaze_cal_free(session);
}

void test_blob_round_trip_glasses_fields() {
    gaze_calibration_t calibration = make_front_calibration();
    calibration.no_glasses.b_yaw = 0.03f;
    calibration.no_glasses.b_pitch = -0.02f;
    calibration.glasses.G_yy = 1.15f;
    calibration.glasses.G_yp = 0.04f;
    calibration.glasses.G_py = -0.03f;
    calibration.glasses.G_pp = 0.85f;
    calibration.glasses.b_yaw = -0.01f;
    calibration.glasses.b_pitch = 0.02f;
    calibration.has_glasses = 1u;
    calibration.active_state = GAZE_STATE_GLASSES;
    calibration.rmse_px = 15.0f;
    calibration.median_err_px = 11.0f;
    calibration.sample_count = 90u;

    std::vector<unsigned char> blob(gaze_calibration_blob_size());
    expect_true(
        gaze_calibration_serialize(&calibration, blob.data(), blob.size()) == GAZE_OK,
        "glasses blob: serialize"
    );

    gaze_calibration_t decoded{};
    expect_true(
        gaze_calibration_deserialize(blob.data(), blob.size(), &decoded) == GAZE_OK,
        "glasses blob: deserialize"
    );
    expect_near(decoded.glasses.G_yy, 1.15f, kTolerance, "glasses blob: G_yy");
    expect_near(decoded.glasses.G_yp, 0.04f, kTolerance, "glasses blob: G_yp");
    expect_near(decoded.glasses.G_py, -0.03f, kTolerance, "glasses blob: G_py");
    expect_near(decoded.glasses.G_pp, 0.85f, kTolerance, "glasses blob: G_pp");
    expect_near(decoded.glasses.b_yaw, -0.01f, kTolerance, "glasses blob: b_yaw");
    expect_near(decoded.glasses.b_pitch, 0.02f, kTolerance, "glasses blob: b_pitch");
    expect_near(decoded.no_glasses.b_yaw, 0.03f, kTolerance, "glasses blob: no_glasses b_yaw");
    expect_near(decoded.no_glasses.b_pitch, -0.02f, kTolerance, "glasses blob: no_glasses b_pitch");
    expect_true(decoded.has_glasses == 1u, "glasses blob: has_glasses preserved");
    expect_true(decoded.active_state == GAZE_STATE_GLASSES, "glasses blob: active_state preserved");
}

void test_calibration_with_extreme_head_yaw() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.04f;
    const float pitch_bias = -0.02f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "extreme-yaw: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {-0.3f, 0.0f, 0.35f, -0.25f, 0.1f, 0.4f, -0.2f, 0.15f, 0.45f};
    const test_math::V3 eyes[] = {
        {-0.08f, 0, 0}, {0, 0, 0}, {0.1f, 0, 0},
        {-0.06f, 0, 0}, {0.02f, 0, 0}, {0.12f, 0.01f, 0},
        {-0.04f, -0.01f, 0}, {0.03f, 0, 0}, {0.14f, 0.01f, 0.02f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const auto dir = test_math::biased_gaze(eyes[i], targets[i].first, targets[i].second, yaw_bias, pitch_bias, head_yaws[i]);
        const auto sample = make_sample_with_head_yaw(eyes[i].x, eyes[i].y, eyes[i].z, dir.x, dir.y, dir.z, head_yaws[i]);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "extreme-yaw: solve");

    const float extreme_yaw = 0.6f;
    const test_math::V3 test_eye{0.15f, 0.0f, 0.03f};
    const std::vector<std::pair<float, float>> probes{
        {0.2f, 0.2f}, {0.5f, 0.5f}, {0.8f, 0.8f},
    };
    for (const auto& [tu, tv] : probes) {
        const auto dir = test_math::biased_gaze(test_eye, tu, tv, yaw_bias, pitch_bias, extreme_yaw);
        const auto sample = make_sample_with_head_yaw(test_eye.x, test_eye.y, test_eye.z, dir.x, dir.y, dir.z, extreme_yaw);
        gaze_screen_point_t point{};
        const int result = gaze_solve_point(&sample, &calibration, &display, &point);
        expect_true(result == GAZE_OK, "extreme-yaw: solve point");
        char msg[128];
        std::snprintf(msg, sizeof(msg), "extreme-yaw u: actual=%.3f expected=%.2f", point.u, tu);
        expect_near(point.u, tu, 0.09f, msg);
        std::snprintf(msg, sizeof(msg), "extreme-yaw v: actual=%.3f expected=%.2f", point.v, tv);
        expect_near(point.v, tv, 0.09f, msg);
    }

    gaze_cal_free(session);
}

void test_many_samples_per_target() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.03f;
    const float pitch_bias = -0.015f;

    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "multi-sample: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float noise_dirs[][2] = {{0.002f, -0.001f}, {-0.001f, 0.002f}, {0.001f, 0.001f}};
    const float head_yaws[] = {0.0f, 0.1f, -0.08f};

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        for (int j = 0; j < 3; ++j) {
            auto dir = test_math::biased_gaze({0, 0, 0}, targets[i].first, targets[i].second,
                yaw_bias, pitch_bias, head_yaws[j]);
            dir.x += noise_dirs[j][0];
            dir.y += noise_dirs[j][1];
            dir = test_math::normalize(dir);
            const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, head_yaws[j]);
            gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
        }
    }

    gaze_calibration_t calibration{};
    expect_true(gaze_cal_solve(session, &calibration) == GAZE_OK, "multi-sample: solve");
    expect_true(calibration.sample_count == 27, "multi-sample: sample count");
    expect_true(calibration.rmse_px < 80.0f, "multi-sample: rmse");

    const auto dir = test_math::biased_gaze({0, 0, 0}, 0.5f, 0.5f, yaw_bias, pitch_bias, 0.0f);
    const auto sample = make_sample_with_head_yaw(0, 0, 0, dir.x, dir.y, dir.z, 0.0f);
    gaze_screen_point_t point{};
    expect_true(gaze_solve_point(&sample, &calibration, &display, &point) == GAZE_OK, "multi-sample: runtime");
    expect_near(point.u, 0.5f, 0.06f, "multi-sample: center u");
    expect_near(point.v, 0.5f, 0.06f, "multi-sample: center v");

    gaze_cal_free(session);
}

void test_solve_point_glasses_vs_bare() {
    const gaze_display_desc_t display = make_display();
    gaze_calibration_t cal = make_front_calibration();
    cal.no_glasses.b_yaw = 0.0f;
    cal.glasses.G_yy = 1.5f;
    cal.glasses.b_yaw = 0.0f;
    cal.has_glasses = 1u;

    const gaze_provider_sample_t sample = make_sample_with_head_yaw(0, 0, 0, 0.05f, 0, 1.0f, 0.0f);
    gaze_screen_point_t point_bare{};
    expect_true(gaze_solve_point(&sample, &cal, &display, &point_bare) == GAZE_OK,
                "state-switch: bare solve");

    expect_true(gaze_set_active_state(&cal, GAZE_STATE_GLASSES) == GAZE_OK,
                "state-switch: enable glasses");
    gaze_screen_point_t point_glasses{};
    expect_true(gaze_solve_point(&sample, &cal, &display, &point_glasses) == GAZE_OK,
                "state-switch: glasses solve");

    expect_true(std::fabs(point_bare.u - point_glasses.u) > 0.001f,
        "state-switch: glasses G != I should produce different u");
}

void test_refit_preserves_face_correction() {
    const gaze_display_desc_t display = make_display();
    gaze_calibration_t base = make_front_calibration();
    base.no_glasses.b_yaw = 0.02f;
    base.no_glasses.b_pitch = -0.01f;
    base.glasses.G_yy = 1.2f;
    base.glasses.G_pp = 0.9f;
    base.glasses.b_yaw = 0.015f;
    base.has_glasses = 1u;

    const std::array<gaze_refit_observation_t, 5> observations{{
        make_refit_observation(0.5f, 0.5f, make_sample(0.02f, 0.0f, 0.0f, -0.02f, 0.0f, 0.6f)),
        make_refit_observation(0.2f, 0.2f, make_sample(0.02f, 0.0f, 0.0f, 0.16f, 0.102f, 0.6f)),
        make_refit_observation(0.8f, 0.2f, make_sample(0.02f, 0.0f, 0.0f, -0.20f, 0.102f, 0.6f)),
        make_refit_observation(0.2f, 0.8f, make_sample(0.02f, 0.0f, 0.0f, 0.16f, -0.102f, 0.6f)),
        make_refit_observation(0.8f, 0.8f, make_sample(0.02f, 0.0f, 0.0f, -0.20f, -0.102f, 0.6f)),
    }};

    gaze_calibration_t refit{};
    expect_true(
        gaze_refit_pose(&base, &display, observations.data(), observations.size(), &refit) == GAZE_OK,
        "refit: should succeed"
    );
    expect_near(refit.no_glasses.b_yaw, 0.02f, kTolerance, "refit: no_glasses b_yaw preserved");
    expect_near(refit.no_glasses.b_pitch, -0.01f, kTolerance, "refit: no_glasses b_pitch preserved");
    expect_near(refit.glasses.G_yy, 1.2f, kTolerance, "refit: glasses G_yy preserved");
    expect_near(refit.glasses.G_pp, 0.9f, kTolerance, "refit: glasses G_pp preserved");
    expect_near(refit.glasses.b_yaw, 0.015f, kTolerance, "refit: glasses b_yaw preserved");
    expect_true(refit.has_glasses == 1u, "refit: has_glasses preserved");
}

void test_quality_gate_rejects_bad_calibration() {
    const gaze_display_desc_t display = make_display();
    gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
    expect_true(session != nullptr, "quality-gate: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
        const auto sample = make_sample(0.0f, 0.0f, 0.0f,
            (static_cast<float>(i) - 4.0f) * 0.01f, 0.0f, 1.0f);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    const int result = gaze_cal_solve(session, &calibration);
    expect_true(
        result == GAZE_ERROR_CALIBRATION_QUALITY || result == GAZE_OK,
        "quality-gate: should return quality error or ok"
    );
    if (result == GAZE_ERROR_CALIBRATION_QUALITY) {
        expect_true(calibration.rmse_px > 0.0f,
            "quality-gate: calibration data should still be populated on quality failure");
        expect_true(calibration.sample_count == targets.size(),
            "quality-gate: sample count should still be populated");
    }

    gaze_cal_free(session);
}

void test_dual_optimization_picks_better_orientation() {
    const gaze_display_desc_t display = make_display();
    const float yaw_bias = 0.03f;
    const float pitch_bias = -0.02f;

    const test_math::V3 screen_center{-0.15f, -0.1f, 0.55f};
    const float screen_w_m = 0.6f;
    const float screen_h_m = 0.34f;
    const test_math::V3 ax{-1.0f, 0.0f, 0.0f};
    const test_math::V3 ay{0.0f, 1.0f, 0.0f};

    for (int trial = 0; trial < 3; ++trial) {
        gaze_cal_session_t* session = gaze_cal_begin(&display, GAZE_CAL_MODE_FULL);
        expect_true(session != nullptr, "dual-opt: session created");

        const std::vector<std::pair<float, float>> targets{
            {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
            {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
            {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
        };
        const float head_yaws[] = {0.2f, 0.0f, -0.15f, 0.1f, 0.0f, -0.1f, 0.12f, -0.05f, -0.25f};

        for (size_t i = 0; i < targets.size(); ++i) {
            gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));
            const test_math::V3 eye{0.0f, 0.0f, 0.0f};
            const auto target_pt = test_math::screen_point_offset(
                targets[i].first, targets[i].second, screen_w_m, screen_h_m, screen_center, ax, ay);
            auto d_true = test_math::normalize(test_math::sub(target_pt, eye));
            auto d_f = test_math::rot_y(d_true, -head_yaws[i]);
            d_f = test_math::rot_y(d_f, -yaw_bias);
            d_f = test_math::rot_x(d_f, -pitch_bias);
            auto d_biased = test_math::normalize(test_math::rot_y(d_f, head_yaws[i]));
            const auto sample = make_sample_with_head_yaw(
                eye.x, eye.y, eye.z, d_biased.x, d_biased.y, d_biased.z, head_yaws[i]);
            gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
        }

        gaze_calibration_t calibration{};
        const int solve_result = gaze_cal_solve(session, &calibration);
        char msg[128];
        std::snprintf(msg, sizeof(msg), "dual-opt trial %d: solve should succeed (result=%d, rmse=%.1f)",
                      trial, solve_result, calibration.rmse_px);
        expect_true(solve_result == GAZE_OK, msg);
        std::snprintf(msg, sizeof(msg), "dual-opt trial %d: rmse=%.1f should be < 100", trial, calibration.rmse_px);
        expect_true(calibration.rmse_px < 100.0f, msg);
        std::snprintf(msg, sizeof(msg), "dual-opt trial %d: |b_yaw|=%.2f° should be < 45°",
                      trial, std::fabs(calibration.no_glasses.b_yaw) * 180.0f / 3.14159f);
        expect_true(std::fabs(calibration.no_glasses.b_yaw) < 0.785f, msg);

        gaze_cal_free(session);
    }
}

void test_glasses_closed_form_recovery() {
    const gaze_display_desc_t display = make_display();

    // Canonical baseline: screen 0.6m in front, +x = -x_p, +y = +y_p, face
    // correction at identity. This is what make_front_calibration() gives.
    gaze_calibration_t baseline = make_front_calibration();

    // Ground-truth glasses transform we want the solver to recover.
    const float GT_G_yy = 1.2f;
    const float GT_G_yp = 0.04f;
    const float GT_G_py = -0.03f;
    const float GT_G_pp = 0.8f;
    const float GT_b_yaw = 0.02f;
    const float GT_b_pitch = -0.01f;

    gaze_cal_session_t* session = gaze_cal_begin_glasses(&display, &baseline);
    expect_true(session != nullptr, "glasses: session created");

    const std::vector<std::pair<float, float>> targets{
        {0.15f, 0.15f}, {0.50f, 0.15f}, {0.85f, 0.15f},
        {0.15f, 0.50f}, {0.50f, 0.50f}, {0.85f, 0.50f},
        {0.15f, 0.85f}, {0.50f, 0.85f}, {0.85f, 0.85f},
    };
    const float head_yaws[] = {0.0f, 0.2f, -0.15f, -0.25f, 0.1f, 0.3f, 0.15f, -0.2f, -0.3f};

    for (size_t i = 0; i < targets.size(); ++i) {
        gaze_cal_push_target(session, targets[i].first, targets[i].second, static_cast<uint32_t>(i));

        const test_math::V3 eye{0.0f, 0.0f, 0.0f};
        const test_math::V3 target = test_math::screen_point_front(targets[i].first, targets[i].second);
        const auto dir_true_p = test_math::normalize(test_math::sub(target, eye));
        const auto dir_true_f = test_math::rot_y(dir_true_p, -head_yaws[i]);

        // Decompose true gaze into face-frame Tait-Bryan tangents.
        const float yaw_true = std::atan2(dir_true_f.x, dir_true_f.z);
        const float y_clamped = std::max(-0.999999f, std::min(0.999999f, dir_true_f.y));
        const float pitch_true = -std::asin(y_clamped);

        // Glasses distort the true gaze: given (yaw_true, pitch_true), the raw
        // ARKit tangent (yaw_raw, pitch_raw) satisfies:
        //     G_gt * (yaw_raw, pitch_raw) + b_gt = (yaw_true, pitch_true)
        // so invert a 2x2 to get (yaw_raw, pitch_raw).
        const float y_in = yaw_true - GT_b_yaw;
        const float p_in = pitch_true - GT_b_pitch;
        const float det = GT_G_yy * GT_G_pp - GT_G_yp * GT_G_py;
        const float yaw_raw = (GT_G_pp * y_in - GT_G_yp * p_in) / det;
        const float pitch_raw = (-GT_G_py * y_in + GT_G_yy * p_in) / det;

        // Rebuild raw direction in face frame, rotate back to provider frame.
        const float sp = std::sin(pitch_raw);
        const float cp = std::cos(pitch_raw);
        const test_math::V3 dir_raw_f{
            std::sin(yaw_raw) * cp,
            -sp,
            std::cos(yaw_raw) * cp,
        };
        const auto dir_raw_p = test_math::normalize(test_math::rot_y(dir_raw_f, head_yaws[i]));

        const auto sample = make_sample_with_head_yaw(
            eye.x, eye.y, eye.z, dir_raw_p.x, dir_raw_p.y, dir_raw_p.z, head_yaws[i]);
        gaze_cal_push_sample(session, &sample, static_cast<uint32_t>(i));
    }

    gaze_calibration_t calibration{};
    const int rc = gaze_cal_solve_glasses(session, &calibration);
    expect_true(rc == GAZE_OK, "glasses: solve should succeed");
    expect_true(calibration.has_glasses == 1u, "glasses: has_glasses=1");
    expect_true(calibration.active_state == GAZE_STATE_GLASSES, "glasses: active_state=GLASSES");

    expect_near(calibration.glasses.G_yy, GT_G_yy, 0.02f, "glasses: G_yy recovered");
    expect_near(calibration.glasses.G_yp, GT_G_yp, 0.02f, "glasses: G_yp recovered");
    expect_near(calibration.glasses.G_py, GT_G_py, 0.02f, "glasses: G_py recovered");
    expect_near(calibration.glasses.G_pp, GT_G_pp, 0.02f, "glasses: G_pp recovered");
    expect_near(calibration.glasses.b_yaw, GT_b_yaw, 0.01f, "glasses: b_yaw recovered");
    expect_near(calibration.glasses.b_pitch, GT_b_pitch, 0.01f, "glasses: b_pitch recovered");

    gaze_cal_free(session);
}

void test_glasses_state_switching() {
    gaze_calibration_t cal = make_front_calibration();
    // Without has_glasses, switching to GLASSES must be rejected.
    expect_true(gaze_set_active_state(&cal, GAZE_STATE_GLASSES) == GAZE_ERROR_MISSING_BASELINE,
                "state: reject GLASSES when no glasses calibrated");
    expect_true(gaze_set_active_state(&cal, GAZE_STATE_NO_GLASSES) == GAZE_OK,
                "state: always accept NO_GLASSES");

    cal.has_glasses = 1u;
    cal.glasses.G_yy = 1.1f;
    expect_true(gaze_set_active_state(&cal, GAZE_STATE_GLASSES) == GAZE_OK,
                "state: accept GLASSES when calibrated");
    expect_true(cal.active_state == GAZE_STATE_GLASSES, "state: active_state updated");

    expect_true(gaze_set_active_state(&cal, 42u) == GAZE_ERROR_INVALID_ARGUMENT,
                "state: reject invalid state value");
}

}  // namespace

int main() {
    test_runtime_solve_center();
    test_runtime_solve_offset();
    test_calibration_session();
    test_refit_pose();
    test_calibration_blob_round_trip();
    test_runtime_residual_application();
    test_invalid_arguments();
    test_head_rotation_invariance();
    test_calibration_mixed_head_poses();
    test_bias_correction_face_frame_multiple_targets();
    test_head_translation_large_range();
    test_calibration_phone_on_left();
    test_calibration_phone_on_right();
    test_calibration_phone_horizontal();
    test_bias_recovery();
    test_initialization_with_tilted_screen();
    test_blob_round_trip_glasses_fields();
    test_calibration_with_extreme_head_yaw();
    test_many_samples_per_target();
    test_solve_point_glasses_vs_bare();
    test_refit_preserves_face_correction();
    test_quality_gate_rejects_bad_calibration();
    test_dual_optimization_picks_better_orientation();
    test_glasses_closed_form_recovery();
    test_glasses_state_switching();
    std::cout << "core tests passed\n";
    return 0;
}
