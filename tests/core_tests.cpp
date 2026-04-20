#include "gaze/gaze_sdk.h"

#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
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

gaze_calibration_t make_front_calibration() {
    gaze_calibration_t calibration{};
    calibration.version = 1.0f;
    calibration.screen_width_mm = 600.0f;
    calibration.screen_height_mm = 340.0f;
    calibration.T_provider_from_screen[0] = -1.0f;
    calibration.T_provider_from_screen[5] = 1.0f;
    calibration.T_provider_from_screen[10] = -1.0f;
    calibration.T_provider_from_screen[15] = 1.0f;
    calibration.T_provider_from_screen[14] = 0.6f;
    calibration.yaw_gain = 1.0f;
    calibration.pitch_gain = 1.0f;
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
    sample.confidence = 1.0f;
    sample.face_distance_m = 0.55f;
    return sample;
}

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

}  // namespace

int main() {
    test_runtime_solve_center();
    test_runtime_solve_offset();
    test_calibration_session();
    std::cout << "core tests passed\n";
    return 0;
}
