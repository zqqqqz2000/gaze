#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <gdiplus.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "gaze/gaze_sdk.h"

#pragma comment(lib, "gdiplus.lib")

namespace {

constexpr uint16_t kDefaultPort = 9000;
constexpr uint8_t kChannelData = 2;
constexpr uint8_t kProviderSampleKind = 1;
constexpr size_t kHeaderLength = 16;
constexpr size_t kProviderSamplePayloadLength = 8 + 4 + 30 * 4;
constexpr float kHorizontalGain = 6.4f;
constexpr float kVerticalGain = 7.2f;
constexpr float kVerticalBias = 0.01f;
constexpr float kBaseRadius = 88.0f;
constexpr float kTransitionSpeed = 1600.0f;
constexpr UINT_PTR kFrameTimer = 1;
constexpr UINT kFrameMs = 16;

struct WireEnvelope {
    uint8_t channel = 0;
    uint8_t kind = 0;
    std::vector<uint8_t> payload;
};

struct BeamTransition {
    Gdiplus::PointF start{};
    Gdiplus::PointF target{};
    double start_time = 0.0;
    double duration = 0.0;
    float trail_start_radius = kBaseRadius;
};

struct SharedState {
    std::mutex mutex;
    std::optional<Gdiplus::PointF> latest_target;
    std::atomic<bool> running{true};
};

class WinSockSession {
public:
    WinSockSession() {
        WSADATA data{};
        const int result = WSAStartup(MAKEWORD(2, 2), &data);
        if (result != 0) {
            throw std::runtime_error("WSAStartup failed: " + std::to_string(result));
        }
    }

    WinSockSession(const WinSockSession&) = delete;
    WinSockSession& operator=(const WinSockSession&) = delete;

    ~WinSockSession() {
        WSACleanup();
    }
};

class SocketHandle {
public:
    explicit SocketHandle(SOCKET socket = INVALID_SOCKET) : socket_(socket) {}

    SocketHandle(const SocketHandle&) = delete;
    SocketHandle& operator=(const SocketHandle&) = delete;

    SocketHandle(SocketHandle&& other) noexcept : socket_(other.socket_) {
        other.socket_ = INVALID_SOCKET;
    }

    SocketHandle& operator=(SocketHandle&& other) noexcept {
        if (this != &other) {
            close();
            socket_ = other.socket_;
            other.socket_ = INVALID_SOCKET;
        }
        return *this;
    }

    ~SocketHandle() {
        close();
    }

    SOCKET get() const {
        return socket_;
    }

    bool valid() const {
        return socket_ != INVALID_SOCKET;
    }

private:
    void close() {
        if (socket_ != INVALID_SOCKET) {
            closesocket(socket_);
            socket_ = INVALID_SOCKET;
        }
    }

    SOCKET socket_ = INVALID_SOCKET;
};

class GdiPlusSession {
public:
    GdiPlusSession() {
        Gdiplus::GdiplusStartupInput input{};
        const Gdiplus::Status status = Gdiplus::GdiplusStartup(&token_, &input, nullptr);
        if (status != Gdiplus::Ok) {
            throw std::runtime_error("GdiplusStartup failed");
        }
    }

    GdiPlusSession(const GdiPlusSession&) = delete;
    GdiPlusSession& operator=(const GdiPlusSession&) = delete;

    ~GdiPlusSession() {
        Gdiplus::GdiplusShutdown(token_);
    }

private:
    ULONG_PTR token_ = 0;
};

uint16_t read_u16_le(const std::vector<uint8_t>& data, size_t offset) {
    return static_cast<uint16_t>(data[offset]) |
        static_cast<uint16_t>(data[offset + 1] << 8);
}

uint32_t read_u32_le(const std::vector<uint8_t>& data, size_t offset) {
    return static_cast<uint32_t>(data[offset]) |
        (static_cast<uint32_t>(data[offset + 1]) << 8) |
        (static_cast<uint32_t>(data[offset + 2]) << 16) |
        (static_cast<uint32_t>(data[offset + 3]) << 24);
}

uint64_t read_u64_le(const std::vector<uint8_t>& data, size_t offset) {
    uint64_t value = 0;
    for (size_t index = 0; index < 8; ++index) {
        value |= static_cast<uint64_t>(data[offset + index]) << (index * 8);
    }
    return value;
}

float read_f32_le(const std::vector<uint8_t>& data, size_t offset) {
    const uint32_t bits = read_u32_le(data, offset);
    float value = 0.0f;
    static_assert(sizeof(bits) == sizeof(value), "float must be 32-bit");
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool next_envelope(std::vector<uint8_t>& buffer, WireEnvelope* out_envelope) {
    if (buffer.size() < kHeaderLength) {
        return false;
    }
    if (!(buffer[0] == 'G' && buffer[1] == 'Z' && buffer[2] == 'E' && buffer[3] == 'P')) {
        throw std::runtime_error("bad wire magic");
    }
    const uint16_t version = read_u16_le(buffer, 4);
    if (version != 1) {
        throw std::runtime_error("unsupported wire version: " + std::to_string(version));
    }
    const uint32_t payload_length = read_u32_le(buffer, 8);
    const size_t frame_length = kHeaderLength + static_cast<size_t>(payload_length);
    if (buffer.size() < frame_length) {
        return false;
    }

    out_envelope->channel = buffer[6];
    out_envelope->kind = buffer[7];
    out_envelope->payload.assign(buffer.begin() + kHeaderLength, buffer.begin() + frame_length);
    buffer.erase(buffer.begin(), buffer.begin() + frame_length);
    return true;
}

void read_f32_array(const std::vector<uint8_t>& data, size_t* offset, float* out_values, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        out_values[index] = read_f32_le(data, *offset);
        *offset += 4;
    }
}

gaze_provider_sample_t decode_provider_sample(const std::vector<uint8_t>& payload) {
    if (payload.size() != kProviderSamplePayloadLength) {
        throw std::runtime_error("bad provider sample payload length");
    }

    gaze_provider_sample_t sample{};
    size_t offset = 0;
    sample.timestamp_ns = read_u64_le(payload, offset);
    offset += 8;
    sample.tracking_flags = read_u32_le(payload, offset);
    offset += 4;

    read_f32_array(payload, &offset, sample.gaze_origin_p_m, 3);
    read_f32_array(payload, &offset, sample.gaze_dir_p, 3);
    read_f32_array(payload, &offset, sample.left_eye_origin_p_m, 3);
    read_f32_array(payload, &offset, sample.left_eye_dir_p, 3);
    read_f32_array(payload, &offset, sample.right_eye_origin_p_m, 3);
    read_f32_array(payload, &offset, sample.right_eye_dir_p, 3);
    read_f32_array(payload, &offset, sample.head_rot_p_f_q, 4);
    read_f32_array(payload, &offset, sample.head_pos_p_m, 3);
    read_f32_array(payload, &offset, sample.look_at_point_f_m, 3);
    sample.confidence = read_f32_le(payload, offset);
    offset += 4;
    sample.face_distance_m = read_f32_le(payload, offset);
    return sample;
}

float clamp01(float value) {
    return std::min(1.0f, std::max(0.0f, value));
}

Gdiplus::PointF map_sample_to_screen(const gaze_provider_sample_t& sample) {
    const int width = GetSystemMetrics(SM_CXSCREEN);
    const int height = GetSystemMetrics(SM_CYSCREEN);
    const float normalized_x = clamp01(0.5f + sample.look_at_point_f_m[0] * kHorizontalGain);
    const float normalized_y = clamp01(0.5f - (sample.look_at_point_f_m[1] - kVerticalBias) * kVerticalGain);
    return Gdiplus::PointF(
        normalized_x * static_cast<float>(width),
        normalized_y * static_cast<float>(height)
    );
}

double now_seconds() {
    LARGE_INTEGER frequency{};
    LARGE_INTEGER counter{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&counter);
    return static_cast<double>(counter.QuadPart) / static_cast<double>(frequency.QuadPart);
}

float distance(Gdiplus::PointF a, Gdiplus::PointF b) {
    const float dx = b.X - a.X;
    const float dy = b.Y - a.Y;
    return std::sqrt(dx * dx + dy * dy);
}

Gdiplus::PointF lerp(Gdiplus::PointF a, Gdiplus::PointF b, float t) {
    return Gdiplus::PointF(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t);
}

SocketHandle make_listener(uint16_t port) {
    SocketHandle listener(socket(AF_INET, SOCK_STREAM, IPPROTO_TCP));
    if (!listener.valid()) {
        throw std::runtime_error("socket failed: " + std::to_string(WSAGetLastError()));
    }

    BOOL reuse = TRUE;
    setsockopt(listener.get(), SOL_SOCKET, SO_REUSEADDR, reinterpret_cast<const char*>(&reuse), sizeof(reuse));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_ANY);
    address.sin_port = htons(port);

    if (bind(listener.get(), reinterpret_cast<sockaddr*>(&address), sizeof(address)) == SOCKET_ERROR) {
        throw std::runtime_error("bind failed: " + std::to_string(WSAGetLastError()));
    }
    if (listen(listener.get(), SOMAXCONN) == SOCKET_ERROR) {
        throw std::runtime_error("listen failed: " + std::to_string(WSAGetLastError()));
    }
    return listener;
}

uint16_t parse_port(int argc, char** argv) {
    if (argc < 2) {
        return kDefaultPort;
    }
    const int port = std::stoi(argv[1]);
    if (port <= 0 || port > 65535) {
        throw std::runtime_error("port must be in 1..65535");
    }
    return static_cast<uint16_t>(port);
}

void network_loop(SharedState* state, uint16_t port) {
    try {
        const WinSockSession winsock;
        SocketHandle listener = make_listener(port);
        std::cout << "GazeWinHost listening on 0.0.0.0:" << port << '\n';
        std::cout << "Run the iPhone demo in LAN mode and connect it to this Windows host.\n";

        sockaddr_in client_address{};
        int client_address_len = sizeof(client_address);
        SocketHandle client(accept(listener.get(), reinterpret_cast<sockaddr*>(&client_address), &client_address_len));
        if (!client.valid()) {
            throw std::runtime_error("accept failed: " + std::to_string(WSAGetLastError()));
        }

        char client_ip[INET_ADDRSTRLEN] = {};
        inet_ntop(AF_INET, &client_address.sin_addr, client_ip, sizeof(client_ip));
        std::cout << "client connected: " << client_ip << ":" << ntohs(client_address.sin_port) << '\n';

        std::vector<uint8_t> buffer;
        std::array<char, 64 * 1024> chunk{};
        uint64_t sample_count = 0;

        while (state->running.load()) {
            const int received = recv(client.get(), chunk.data(), static_cast<int>(chunk.size()), 0);
            if (received == 0) {
                std::cout << "client disconnected\n";
                break;
            }
            if (received == SOCKET_ERROR) {
                throw std::runtime_error("recv failed: " + std::to_string(WSAGetLastError()));
            }

            buffer.insert(buffer.end(), chunk.begin(), chunk.begin() + received);
            WireEnvelope envelope{};
            while (next_envelope(buffer, &envelope)) {
                if (envelope.channel != kChannelData || envelope.kind != kProviderSampleKind) {
                    continue;
                }
                const gaze_provider_sample_t sample = decode_provider_sample(envelope.payload);
                const Gdiplus::PointF point = map_sample_to_screen(sample);
                {
                    std::lock_guard<std::mutex> lock(state->mutex);
                    state->latest_target = point;
                }

                ++sample_count;
                if (sample_count == 1 || sample_count % 120 == 0) {
                    std::cout << "#" << sample_count
                              << " confidence=" << std::fixed << std::setprecision(2) << sample.confidence
                              << " faceDistanceM=" << std::setprecision(3) << sample.face_distance_m
                              << " screen=(" << static_cast<int>(point.X) << ", " << static_cast<int>(point.Y) << ")"
                              << '\n';
                }
            }
        }
    } catch (const std::exception& error) {
        std::cerr << "network error: " << error.what() << '\n';
    }
}

class OverlayRenderer {
public:
    explicit OverlayRenderer(SharedState* state) : state_(state) {}

    void pull_latest_target() {
        std::optional<Gdiplus::PointF> target;
        {
            std::lock_guard<std::mutex> lock(state_->mutex);
            target = state_->latest_target;
        }
        if (!target) {
            return;
        }

        const double time = now_seconds();
        const Gdiplus::PointF live = resolved_lead_point(time).value_or(*target);
        settled_point_ = *target;

        const float dist = distance(live, *target);
        if (dist < 1.0f) {
            transition_.reset();
            return;
        }

        transition_ = BeamTransition{
            live,
            *target,
            time,
            std::max(1.0 / 120.0, static_cast<double>(dist / kTransitionSpeed)),
            kBaseRadius,
        };
    }

    void render(HWND hwnd) {
        pull_latest_target();

        const int width = GetSystemMetrics(SM_CXSCREEN);
        const int height = GetSystemMetrics(SM_CYSCREEN);
        HDC screen_dc = GetDC(nullptr);
        HDC memory_dc = CreateCompatibleDC(screen_dc);

        BITMAPINFO bitmap_info{};
        bitmap_info.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
        bitmap_info.bmiHeader.biWidth = width;
        bitmap_info.bmiHeader.biHeight = -height;
        bitmap_info.bmiHeader.biPlanes = 1;
        bitmap_info.bmiHeader.biBitCount = 32;
        bitmap_info.bmiHeader.biCompression = BI_RGB;

        void* bits = nullptr;
        HBITMAP bitmap = CreateDIBSection(screen_dc, &bitmap_info, DIB_RGB_COLORS, &bits, nullptr, 0);
        HGDIOBJ old_bitmap = SelectObject(memory_dc, bitmap);

        Gdiplus::Graphics graphics(memory_dc);
        graphics.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
        graphics.Clear(Gdiplus::Color(0, 0, 0, 0));
        draw_beam(graphics);

        POINT source{0, 0};
        POINT destination{0, 0};
        SIZE size{width, height};
        BLENDFUNCTION blend{};
        blend.BlendOp = AC_SRC_OVER;
        blend.SourceConstantAlpha = 255;
        blend.AlphaFormat = AC_SRC_ALPHA;
        UpdateLayeredWindow(hwnd, screen_dc, &destination, &size, memory_dc, &source, 0, &blend, ULW_ALPHA);

        SelectObject(memory_dc, old_bitmap);
        DeleteObject(bitmap);
        DeleteDC(memory_dc);
        ReleaseDC(nullptr, screen_dc);
    }

private:
    std::optional<Gdiplus::PointF> resolved_lead_point(double time) const {
        if (!transition_) {
            return settled_point_;
        }
        if (progress(time) >= 1.0f) {
            return settled_point_;
        }
        return transition_->target;
    }

    float progress(double time) const {
        if (!transition_ || transition_->duration <= 0.0) {
            return 1.0f;
        }
        return std::clamp(static_cast<float>((time - transition_->start_time) / transition_->duration), 0.0f, 1.0f);
    }

    void draw_beam(Gdiplus::Graphics& graphics) {
        const double time = now_seconds();
        const auto lead = resolved_lead_point(time);
        if (!lead) {
            return;
        }

        Gdiplus::GraphicsPath path;
        if (transition_ && progress(time) < 1.0f) {
            const float p = progress(time);
            const Gdiplus::PointF trail = lerp(transition_->start, transition_->target, p);
            const float trail_radius = std::max(1.0f, transition_->trail_start_radius * (1.0f - p));
            add_capsule_path(path, trail, *lead, trail_radius, kBaseRadius);
        } else {
            path.AddEllipse(lead->X - kBaseRadius, lead->Y - kBaseRadius, kBaseRadius * 2.0f, kBaseRadius * 2.0f);
        }

        Gdiplus::Pen glow_outer(Gdiplus::Color(26, 117, 105, 255), 18.0f);
        Gdiplus::Pen glow_inner(Gdiplus::Color(46, 117, 105, 255), 8.0f);
        Gdiplus::SolidBrush fill(Gdiplus::Color(46, 117, 105, 255));
        Gdiplus::Pen edge(Gdiplus::Color(235, 255, 255, 255), 2.4f);
        graphics.DrawPath(&glow_outer, &path);
        graphics.DrawPath(&glow_inner, &path);
        graphics.FillPath(&fill, &path);
        graphics.DrawPath(&edge, &path);
    }

    void add_capsule_path(
        Gdiplus::GraphicsPath& path,
        Gdiplus::PointF start,
        Gdiplus::PointF end,
        float start_radius,
        float end_radius
    ) {
        const float dist = distance(start, end);
        if (dist <= 1.0f) {
            const float radius = std::max(start_radius, end_radius);
            path.AddEllipse(end.X - radius, end.Y - radius, radius * 2.0f, radius * 2.0f);
            return;
        }

        Gdiplus::Pen connector(Gdiplus::Color(255, 255, 255, 255), std::max(start_radius, end_radius) * 2.0f);
        connector.SetStartCap(Gdiplus::LineCapRound);
        connector.SetEndCap(Gdiplus::LineCapRound);

        // GDI+ has no direct "stroke to path" API. This flattened shape closely
        // matches the macOS merged-beam visual: a soft rounded trail connected
        // to the lead circle, with the same glow/fill/stroke passes applied.
        path.AddEllipse(start.X - start_radius, start.Y - start_radius, start_radius * 2.0f, start_radius * 2.0f);
        path.AddEllipse(end.X - end_radius, end.Y - end_radius, end_radius * 2.0f, end_radius * 2.0f);
        const float angle = std::atan2(end.Y - start.Y, end.X - start.X);
        const float nx = -std::sin(angle);
        const float ny = std::cos(angle);
        const float radius = std::max(start_radius, end_radius);
        Gdiplus::PointF points[4] = {
            Gdiplus::PointF(start.X + nx * radius, start.Y + ny * radius),
            Gdiplus::PointF(end.X + nx * radius, end.Y + ny * radius),
            Gdiplus::PointF(end.X - nx * radius, end.Y - ny * radius),
            Gdiplus::PointF(start.X - nx * radius, start.Y - ny * radius),
        };
        path.AddPolygon(points, 4);
    }

    SharedState* state_;
    std::optional<Gdiplus::PointF> settled_point_;
    std::optional<BeamTransition> transition_;
};

LRESULT CALLBACK overlay_proc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    auto* renderer = reinterpret_cast<OverlayRenderer*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
    switch (message) {
    case WM_CREATE: {
        auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
        SetWindowLongPtr(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
        SetTimer(hwnd, kFrameTimer, kFrameMs, nullptr);
        return 0;
    }
    case WM_TIMER:
        if (wparam == kFrameTimer && renderer != nullptr) {
            renderer->render(hwnd);
        }
        return 0;
    case WM_DESTROY:
        KillTimer(hwnd, kFrameTimer);
        PostQuitMessage(0);
        return 0;
    default:
        return DefWindowProc(hwnd, message, wparam, lparam);
    }
}

HWND create_overlay_window(HINSTANCE instance, OverlayRenderer* renderer) {
    const wchar_t* class_name = L"GazeWinHostOverlay";
    WNDCLASS wc{};
    wc.lpfnWndProc = overlay_proc;
    wc.hInstance = instance;
    wc.lpszClassName = class_name;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    RegisterClass(&wc);

    const int width = GetSystemMetrics(SM_CXSCREEN);
    const int height = GetSystemMetrics(SM_CYSCREEN);
    HWND hwnd = CreateWindowEx(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        class_name,
        L"GazeWinHost Overlay",
        WS_POPUP,
        0,
        0,
        width,
        height,
        nullptr,
        nullptr,
        instance,
        renderer
    );
    if (hwnd == nullptr) {
        throw std::runtime_error("CreateWindowEx failed: " + std::to_string(GetLastError()));
    }

    ShowWindow(hwnd, SW_SHOWNA);
    return hwnd;
}

} // namespace

int main(int argc, char** argv) {
    try {
        const uint16_t port = parse_port(argc, argv);
        const GdiPlusSession gdiplus;
        SharedState state;
        OverlayRenderer renderer(&state);

        std::thread network_thread(network_loop, &state, port);
        HWND hwnd = create_overlay_window(GetModuleHandle(nullptr), &renderer);
        renderer.render(hwnd);

        MSG message{};
        while (GetMessage(&message, nullptr, 0, 0) > 0) {
            TranslateMessage(&message);
            DispatchMessage(&message);
        }

        state.running.store(false);
        if (network_thread.joinable()) {
            network_thread.detach();
        }
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "GazeWinHost error: " << error.what() << '\n';
        return 1;
    }
}
