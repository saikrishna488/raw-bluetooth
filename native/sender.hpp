#pragma once
#include "core.hpp"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <map>
#include <mutex>
#include <pthread.h>
#include <sys/qos.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>

namespace rawbt {
// Versioned compact records for the private local input socket. This keeps the
// latency-sensitive path out of Python timers and JSON serialization.
enum class InputKind : uint8_t { mouse = 1, keyboard = 2, release = 3 };
struct InputReport {
    std::string device;
    InputKind kind = InputKind::mouse;
    int32_t x = 0, y = 0, wheel = 0, pan = 0;
    uint8_t button_mask = 0, button_values = 0;
    std::vector<uint16_t> keys, consumers;
};

class DatagramSender {
    static constexpr size_t motion_backlog_threshold = 4;
    struct Packet { std::string bytes; bool motion = false; uint64_t device = 0; int32_t x = 0, y = 0, wheel = 0, pan = 0; };
    FD socket;
    std::mutex mutex;
    std::condition_variable condition;
    std::deque<Packet> queue;
    std::map<uint64_t, uint8_t> buttons;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::string failure;
    bool sending = false;
    static int16_t axis(int32_t value) { return int16_t(std::max(-32768, std::min(32767, value))); }
    static void u16(std::string& out, uint16_t value) { out.push_back(char(value)); out.push_back(char(value >> 8)); }
    static void u64(std::string& out, uint64_t value) { for (unsigned i = 0; i < 8; ++i) out.push_back(char(value >> (i * 8))); }
    static uint64_t now() { timespec time{}; clock_gettime(CLOCK_REALTIME, &time); return uint64_t(time.tv_sec) * 1000000000ULL + uint64_t(time.tv_nsec); }
    static std::string mouse(uint64_t device, int32_t x, int32_t y, int32_t wheel, int32_t pan, uint8_t flags = 0, uint8_t values = 0) {
        std::string out; out.reserve(flags ? 21 : 28); out.push_back(1); out.push_back(uint8_t(InputKind::mouse)); out.push_back(flags); out.push_back(0); u64(out, device);
        u16(out, uint16_t(axis(x))); u16(out, uint16_t(axis(y))); u16(out, uint16_t(axis(wheel))); u16(out, uint16_t(axis(pan)));
        if (flags) out.push_back(char(values)); else u64(out, now()); return out;
    }
    static std::string keyboard(uint64_t device, const InputReport& report) {
        if (report.keys.size() > 255 || report.consumers.size() > 255) throw std::invalid_argument("Excessive keyboard state");
        std::string out; out.reserve(14 + 2 * (report.keys.size() + report.consumers.size())); out.push_back(1); out.push_back(uint8_t(InputKind::keyboard)); out.push_back(0); out.push_back(0); u64(out, device);
        out.push_back(char(report.keys.size())); out.push_back(char(report.consumers.size())); for (auto item : report.keys) u16(out, item); for (auto item : report.consumers) u16(out, item); return out;
    }
    static std::string release(uint64_t device) { std::string out; out.push_back(1); out.push_back(uint8_t(InputKind::release)); out.push_back(0); out.push_back(0); u64(out, device); return out; }
    static uint64_t device_id(const std::string& name) {
        // Stable across independent sender instances so concurrently connected
        // devices cannot share state in the desktop relay.
        uint64_t value = 1469598103934665603ULL;
        for (auto byte : name) { value ^= uint8_t(byte); value *= 1099511628211ULL; }
        return value;
    }
    void enqueue_locked(Packet packet) {
        if (stopping || !failure.empty()) throw std::runtime_error("Pointer helper disconnected" + (failure.empty() ? "" : ": " + failure));
        // Preserve the peripheral's normal report cadence. Only merge once a
        // genuine backlog exists, rather than turning one queued packet into
        // a lower-rate stream during ordinary scheduling jitter.
        if (packet.motion && queue.size() >= motion_backlog_threshold && queue.back().motion && queue.back().device == packet.device) {
            auto& prior = queue.back(); prior.x += packet.x; prior.y += packet.y; prior.wheel += packet.wheel; prior.pan += packet.pan;
            prior.bytes = mouse(prior.device, prior.x, prior.y, prior.wheel, prior.pan);
        } else {
            if (queue.size() >= 32) queue.erase(std::remove_if(queue.begin(), queue.end(), [](const Packet& item) { return item.motion; }), queue.end());
            if (queue.size() >= 32) throw std::runtime_error("Pointer control queue is full"); queue.push_back(std::move(packet));
        }
        condition.notify_all();
    }
    void run() noexcept {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        for (;;) {
            Packet packet;
            { std::unique_lock<std::mutex> lock(mutex); condition.wait(lock, [&] { return stopping || !queue.empty(); }); if (stopping) break; packet = std::move(queue.front()); queue.pop_front(); sending = true; }
            while (!stopping) {
                auto count = ::send(socket.value, packet.bytes.data(), packet.bytes.size(), 0);
                if (count == ssize_t(packet.bytes.size())) break;
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == ENOBUFS || errno == EAGAIN || errno == EWOULDBLOCK)) { std::unique_lock<std::mutex> lock(mutex); condition.wait_for(lock, std::chrono::milliseconds(5), [&] { return stopping.load(); }); continue; }
                std::lock_guard<std::mutex> lock(mutex); failure = count < 0 ? std::strerror(errno) : "Partial pointer datagram"; queue.clear(); break;
            }
            { std::lock_guard<std::mutex> lock(mutex); sending = false; } condition.notify_all();
        }
    }
public:
    explicit DatagramSender(const std::string& path) : socket(::socket(AF_UNIX, SOCK_DGRAM, 0)) {
        if (socket.value < 0) system_error("create pointer socket"); if (path.size() >= sizeof(sockaddr_un::sun_path)) throw std::invalid_argument("Pointer socket path too long");
        sockaddr_un address{}; address.sun_family = AF_UNIX; std::strcpy(address.sun_path, path.c_str()); if (::connect(socket.value, reinterpret_cast<sockaddr*>(&address), sizeof(address))) system_error("connect pointer helper");
        if (fcntl(socket.value, F_SETFL, O_NONBLOCK) < 0) system_error("set pointer socket nonblocking"); int yes = 1; setsockopt(socket.value, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes)); worker = std::thread([this] { run(); });
    }
    void enqueue_report(const InputReport& report) {
        std::lock_guard<std::mutex> lock(mutex); auto device = device_id(report.device);
        if (report.kind == InputKind::release) { buttons.erase(device); enqueue_locked({release(device)}); return; }
        if (report.kind == InputKind::keyboard) { enqueue_locked({keyboard(device, report)}); return; }
        uint8_t state = buttons[device], changed = report.button_mask & (state ^ report.button_values); state = (state & ~report.button_mask) | (report.button_values & report.button_mask); buttons[device] = state;
        if (report.x || report.y || report.wheel || report.pan) enqueue_locked({mouse(device, report.x, report.y, report.wheel, report.pan), true, device, report.x, report.y, report.wheel, report.pan});
        if (changed) enqueue_locked({mouse(device, 0, 0, 0, 0, 1, state)});
    }
    bool drain(double seconds) { std::unique_lock<std::mutex> lock(mutex); return condition.wait_for(lock, std::chrono::duration<double>(seconds), [&] { return queue.empty() && !sending; }); }
    void close() { if (!worker.joinable()) return; drain(1.0); stopping = true; condition.notify_all(); worker.join(); }
    ~DatagramSender() { close(); }
};
}
