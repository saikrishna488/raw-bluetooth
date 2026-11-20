#pragma once
#include "core.hpp"
#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>

namespace rawbt {
class DatagramSender {
    FD socket;
    std::mutex mutex;
    std::condition_variable condition;
    struct Packet { std::string bytes; bool coalescible; };
    std::deque<Packet> queue;
    std::thread worker;
    std::atomic<bool> stopping{false};
    std::string failure;
    bool sending = false;
    void run() noexcept {
        for (;;) {
            Packet packet;
            {
                std::unique_lock<std::mutex> lock(mutex);
                condition.wait(lock, [&] { return stopping || !queue.empty(); });
                if (stopping) break;
                packet = std::move(queue.front()); queue.pop_front(); sending = true;
            }
            while (!stopping) {
                auto count = ::send(socket.value, packet.bytes.data(), packet.bytes.size(), 0);
                if (count == ssize_t(packet.bytes.size())) break;
                if (count < 0 && errno == EINTR) continue;
                if (count < 0 && (errno == ENOBUFS || errno == EAGAIN || errno == EWOULDBLOCK)) {
                    // macOS may keep POLLOUT set while a datagram queue is full.
                    // A timed condition wait avoids spinning and wakes on close.
                    std::unique_lock<std::mutex> lock(mutex);
                    condition.wait_for(lock, std::chrono::milliseconds(5), [&] { return stopping.load(); });
                    continue;
                }
                std::lock_guard<std::mutex> lock(mutex);
                failure = count < 0 ? std::strerror(errno) : "Partial pointer datagram";
                queue.clear();
                break;
            }
            {
                std::lock_guard<std::mutex> lock(mutex);
                sending = false;
            }
            condition.notify_all();
        }
    }
public:
    explicit DatagramSender(const std::string& path) : socket(::socket(AF_UNIX, SOCK_DGRAM, 0)) {
        if (socket.value < 0) system_error("create pointer socket");
        if (path.size() >= sizeof(sockaddr_un::sun_path)) throw std::invalid_argument("Pointer socket path too long");
        sockaddr_un address{}; address.sun_family = AF_UNIX; std::strcpy(address.sun_path, path.c_str());
        if (::connect(socket.value, reinterpret_cast<sockaddr*>(&address), sizeof(address))) system_error("connect pointer helper");
        if (fcntl(socket.value, F_SETFL, O_NONBLOCK) < 0) system_error("set pointer socket nonblocking");
        int yes = 1; setsockopt(socket.value, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
        worker = std::thread([this] { run(); });
    }
    void enqueue(std::string packet, bool coalescible = false) {
        std::lock_guard<std::mutex> lock(mutex);
        if (stopping || !failure.empty()) throw std::runtime_error("Pointer helper disconnected" + (failure.empty() ? "" : ": " + failure));
        if (coalescible && !queue.empty() && queue.back().coalescible) {
            // Keep only the newest movement while delivery is stalled. Never
            // replace across a button or keyboard transition: their ordering
            // is observable and must remain exact.
            queue.back() = {std::move(packet), true};
            condition.notify_all();
            return;
        }
        if (queue.size() >= 32) {
            // Mouse movement is advisory: keep button and keyboard transitions,
            // but never make the cursor replay a long stale backlog.
            queue.erase(std::remove_if(queue.begin(), queue.end(), [](const Packet& item) { return item.coalescible; }), queue.end());
        }
        if (queue.size() >= 32) throw std::runtime_error("Pointer control queue is full");
        queue.push_back({std::move(packet), coalescible}); condition.notify_all();
    }
    bool drain(double seconds) {
        std::unique_lock<std::mutex> lock(mutex);
        return condition.wait_for(lock, std::chrono::duration<double>(seconds), [&] { return queue.empty() && !sending; });
    }
    void close() {
        if (!worker.joinable()) return;
        drain(1.0); stopping = true; condition.notify_all(); worker.join();
    }
    ~DatagramSender() { close(); }
};
}
