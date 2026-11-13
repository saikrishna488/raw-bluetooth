#pragma once
#include "core.hpp"
#include <ApplicationServices/ApplicationServices.h>
#include <array>
#include <cmath>
#include <limits>
#include <csignal>
#include <iostream>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>

namespace rawbt {
inline CGPoint clamp_pointer(CGPoint point, const Json& screens) {
    CGPoint result = point;
    double best = std::numeric_limits<double>::infinity();
    for (const auto& screen : screens) {
        double left = screen.at(0), top = screen.at(1), width = screen.at(2), height = screen.at(3);
        if (width < 1 || height < 1) continue;
        CGPoint candidate{std::clamp(point.x, left, left + width - 1), std::clamp(point.y, top, top + height - 1)};
        double distance = std::pow(candidate.x - point.x, 2) + std::pow(candidate.y - point.y, 2);
        if (distance < best) { result = candidate; best = distance; }
    }
    return result;
}
struct Pointer {
    std::array<bool, 8> buttons{};
    Pointer() { if (!AXIsProcessTrusted()) throw std::runtime_error("Pointer output requires Accessibility permission for this executable. Use --dry-run to test Bluetooth without pointer access."); }
    void post(CGEventRef event) {
        if (!event) throw std::runtime_error("CoreGraphics failed to create event");
        CGEventPost(kCGHIDEventTap, event);
        CFRelease(event);
    }
    Json displays() const {
        uint32_t count = 0;
        Json result = Json::array();
        if (CGGetActiveDisplayList(0, nullptr, &count) != kCGErrorSuccess || !count) return result;
        std::vector<CGDirectDisplayID> ids(count);
        if (CGGetActiveDisplayList(count, ids.data(), &count) != kCGErrorSuccess) return result;
        for (uint32_t i = 0; i < count; ++i) {
            auto rect = CGDisplayBounds(ids[i]);
            result.push_back({rect.origin.x, rect.origin.y, rect.size.width, rect.size.height});
        }
        return result;
    }
    void apply(const Json& report) {
        auto current = CGEventCreate(nullptr);
        if (!current) throw std::runtime_error("Cannot read pointer position");
        auto pos = CGEventGetLocation(current);
        CFRelease(current);
        auto screens = displays();
        auto origin = clamp_pointer(pos, screens);
        double dx = report.value("x", 0.0), dy = report.value("y", 0.0);
        pos = clamp_pointer({origin.x + dx, origin.y + dy}, screens);
        if (dx || dy) {
            int button = 0;
            for (int i = 0; i < 8; ++i) if (buttons[i]) { button = i; break; }
            bool held = std::any_of(buttons.begin(), buttons.end(), [](bool down) { return down; });
            auto type = !held ? kCGEventMouseMoved : button == 0 ? kCGEventLeftMouseDragged : button == 1 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged;
            auto event = CGEventCreateMouseEvent(nullptr, type, pos, CGMouseButton(button));
            if (event) {
                CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, int64_t(std::nearbyint(pos.x - origin.x)));
                CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, int64_t(std::nearbyint(pos.y - origin.y)));
            }
            post(event);
        }
        for (int i = 0; i < 8; ++i) {
            bool down = report.value("button" + std::to_string(i + 1), buttons[i]);
            if (down == buttons[i]) continue;
            auto type = i == 0 ? (down ? kCGEventLeftMouseDown : kCGEventLeftMouseUp) :
                i == 1 ? (down ? kCGEventRightMouseDown : kCGEventRightMouseUp) : (down ? kCGEventOtherMouseDown : kCGEventOtherMouseUp);
            post(CGEventCreateMouseEvent(nullptr, type, pos, CGMouseButton(i)));
            buttons[i] = down;
        }
        int wheel = report.value("wheel", 0), pan = report.value("pan", 0);
        if (wheel || pan) post(CGEventCreateScrollWheelEvent(nullptr, kCGScrollEventUnitLine, 2, wheel, pan));
    }
    void release() { Json report; for (int i = 1; i <= 8; ++i) report["button" + std::to_string(i)] = false; apply(report); }
};
inline volatile sig_atomic_t pointer_stopping = 0;
inline void stop_pointer(int) { pointer_stopping = 1; }
inline void pointer_bridge(const std::string& path, double duration) {
    Pointer pointer;
    if (path.size() >= sizeof(sockaddr_un::sun_path)) throw std::invalid_argument("Pointer socket path too long");
    sockaddr_un address{}; address.sun_family = AF_UNIX; std::strcpy(address.sun_path, path.c_str());
    struct stat info{};
    if (lstat(path.c_str(), &info) == 0) {
        if (!S_ISSOCK(info.st_mode) || info.st_uid != getuid()) throw std::runtime_error("Unexpected file at pointer socket path");
        FD probe(::socket(AF_UNIX, SOCK_DGRAM, 0));
        if (probe.value < 0) system_error("create probe socket");
        if (::connect(probe.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0) throw std::runtime_error("Another pointer helper is already running");
        if (errno != ECONNREFUSED && errno != ENOENT) system_error("probe pointer socket");
        if (::unlink(path.c_str()) && errno != ENOENT) system_error("remove stale pointer socket");
    }
    FD socket(::socket(AF_UNIX, SOCK_DGRAM, 0));
    if (socket.value < 0) system_error("create pointer receiver");
    if (bind(socket.value, reinterpret_cast<sockaddr*>(&address), sizeof(address))) system_error("bind pointer receiver");
    struct Cleanup {
        std::string path;
        Pointer& pointer;
        ~Cleanup() { try { pointer.release(); } catch (...) {} ::unlink(path.c_str()); ::unlink((fs::path(path).parent_path() / "pointer.ready").c_str()); }
    } cleanup{path, pointer};
    if (chmod(path.c_str(), 0600)) system_error("pointer socket permissions");
    atomic_write(fs::path(path).parent_path() / "pointer.ready", std::to_string(getpid()));
    std::cout << "POINTER READY socket=" << path << std::endl;
    pointer_stopping = 0;
    auto previous_term = std::signal(SIGTERM, stop_pointer), previous_int = std::signal(SIGINT, stop_pointer);
    struct Signals {
        decltype(previous_term) term, interrupt;
        ~Signals() { std::signal(SIGTERM, term); std::signal(SIGINT, interrupt); }
    } signals{previous_term, previous_int};
    auto deadline = std::chrono::steady_clock::now() + std::chrono::duration<double>(duration);
    size_t reports = 0;
    while (!pointer_stopping && std::chrono::steady_clock::now() < deadline) {
        pollfd state{socket.value, POLLIN, 0};
        int result = poll(&state, 1, 200);
        if (result < 0 && errno == EINTR) continue;
        if (result < 0) system_error("read pointer receiver");
        if (!result) continue;
        char bytes[4096];
        auto length = recv(socket.value, bytes, sizeof(bytes), 0);
        if (length < 0) continue;
        auto report = Json::parse(bytes, bytes + length, nullptr, false);
        if (!report.is_object()) continue;
        Json filtered = Json::object();
        for (auto name : {"x", "y", "wheel", "pan"}) {
            auto i = report.find(name);
            if (i != report.end() && i->is_number_integer() && *i >= -32768 && *i <= 32767) filtered[name] = *i;
        }
        for (int i = 1; i <= 8; ++i) {
            auto key = "button" + std::to_string(i);
            if (report.contains(key) && report[key].is_boolean()) filtered[key] = report[key];
        }
        pointer.apply(filtered);
        if (++reports <= 5) std::cout << "POSTED " << filtered.dump() << std::endl;
    }
    std::cout << "Pointer helper stopped after " << reports << " reports" << std::endl;
}
}
