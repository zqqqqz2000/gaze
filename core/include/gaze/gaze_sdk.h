#ifndef GAZE_GAZE_SDK_H_
#define GAZE_GAZE_SDK_H_

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    GAZE_TRACKING_FLAG_TRACKED = 1u << 0,
    GAZE_TRACKING_FLAG_LOW_CONFIDENCE = 1u << 1,
    GAZE_TRACKING_FLAG_LOST = 1u << 2
};

enum {
    GAZE_OK = 0,
    GAZE_ERROR_INVALID_ARGUMENT = -1,
    GAZE_ERROR_NOT_ENOUGH_DATA = -2,
    GAZE_ERROR_NUMERIC_FAILURE = -3,
    GAZE_ERROR_OUT_OF_RANGE = -4
};

typedef struct {
    uint64_t timestamp_ns;
    uint32_t tracking_flags;

    float gaze_origin_p_m[3];
    float gaze_dir_p[3];

    float left_eye_origin_p_m[3];
    float left_eye_dir_p[3];
    float right_eye_origin_p_m[3];
    float right_eye_dir_p[3];

    float head_rot_p_f_q[4];
    float head_pos_p_m[3];
    float look_at_point_f_m[3];

    float confidence;
    float face_distance_m;
} gaze_provider_sample_t;

typedef struct {
    float screen_width_mm;
    float screen_height_mm;
    uint32_t width_px;
    uint32_t height_px;
} gaze_display_desc_t;

typedef struct {
    float version;
    float screen_width_mm;
    float screen_height_mm;
    float T_provider_from_screen[16];

    float yaw_bias_rad;
    float pitch_bias_rad;
    float yaw_gain;
    float pitch_gain;

    float residual_u[6];
    float residual_v[6];

    float rmse_px;
    float median_err_px;
    uint32_t sample_count;
} gaze_calibration_t;

typedef struct {
    float u;
    float v;
    float x_px;
    float y_px;
    float hit_point_p_m[3];
    float distance_to_screen_plane_m;
    float ray_plane_angle_rad;
    float confidence;
    uint32_t inside_screen;
} gaze_screen_point_t;

typedef struct {
    float u;
    float v;
    uint32_t target_id;
} gaze_target_t;

typedef struct {
    float u;
    float v;
    gaze_provider_sample_t sample;
} gaze_refit_observation_t;

typedef enum {
    GAZE_CAL_MODE_FULL = 0,
    GAZE_CAL_MODE_QUICK_REFIT = 1,
    GAZE_CAL_MODE_VALIDATION = 2
} gaze_cal_mode_t;

typedef struct gaze_cal_session gaze_cal_session_t;

const char* gaze_get_version_string(void);

gaze_cal_session_t* gaze_cal_begin(const gaze_display_desc_t* display, gaze_cal_mode_t mode);
void gaze_cal_free(gaze_cal_session_t* session);

int gaze_cal_push_target(gaze_cal_session_t* session, float u, float v, uint32_t target_id);
int gaze_cal_push_sample(
    gaze_cal_session_t* session,
    const gaze_provider_sample_t* sample,
    uint32_t target_id
);
int gaze_cal_solve(gaze_cal_session_t* session, gaze_calibration_t* out_calibration);

int gaze_solve_point(
    const gaze_provider_sample_t* sample,
    const gaze_calibration_t* calibration,
    const gaze_display_desc_t* display,
    gaze_screen_point_t* out_point
);

int gaze_refit_pose(
    const gaze_calibration_t* base_calibration,
    const gaze_display_desc_t* display,
    const gaze_refit_observation_t* observations,
    size_t observation_count,
    gaze_calibration_t* out_calibration
);

#ifdef __cplusplus
}
#endif

#endif
