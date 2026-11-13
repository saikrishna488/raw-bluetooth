#include "usb.hpp"
#include "hci.hpp"
#include <atomic>
#include <csignal>
#include <iostream>
#include <mutex>
#include <poll.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <thread>

using namespace rawbt;
namespace {
volatile sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }
void check(int result, const char* operation) {
    if (result < 0) throw std::runtime_error(std::string(operation) + ": " + libusb_error_name(result));
}
void timeout(int fd, short events, int milliseconds) {
    pollfd state{fd, events, 0};
    int result;
    do { result = poll(&state, 1, milliseconds); } while (result < 0 && errno == EINTR && !stopping);
    if (result <= 0 || !(state.revents & events)) throw std::runtime_error("USB client disconnected or timed out");
}
void send_bytes(int fd, const uint8_t* data, size_t length) {
    while (length) {
        auto count = send(fd, data, length, MSG_DONTWAIT);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { timeout(fd, POLLOUT, 1000); continue; }
        if (count <= 0) throw std::runtime_error("USB client stopped reading");
        data += count; length -= size_t(count);
    }
}
void send_json(int fd, const Json& data) {
    auto bytes = data.dump() + "\n";
    send_bytes(fd, reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size());
}
std::string request(int fd) {
    std::string line;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (line.size() < 4096) {
        int remaining = int(std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now()).count());
        if (remaining <= 0) throw std::runtime_error("USB request timed out");
        timeout(fd, POLLIN, remaining);
        char byte;
        auto count = recv(fd, &byte, 1, 0);
        if (count < 0 && errno == EINTR) continue;
        if (count != 1) throw std::runtime_error("Incomplete USB request");
        if (byte == '\n') return line;
        line += byte;
    }
    throw std::invalid_argument("Oversized USB request");
}
struct Device {
    USBContext context;
    libusb_device_handle* handle = nullptr;
    Endpoints ep;
    bool claimed = false;
    explicit Device(const std::string& name) {
        auto available = discover_adapters();
        select_transport(name, available);
        USBDevices devices(context.value);
        for (ssize_t i = 0; i < devices.count; ++i) {
            libusb_device_descriptor descriptor{};
            if (libusb_get_device_descriptor(devices.list[i], &descriptor) || transport_name({descriptor.idVendor, descriptor.idProduct}) != lower(name)) continue;
            if (!endpoints(devices.list[i], ep)) throw std::runtime_error("Adapter no longer has a valid HCI interface");
            check(libusb_open(devices.list[i], &handle), "open adapter");
            break;
        }
        if (!handle) throw std::runtime_error("USB adapter disappeared");
        try {
            check(libusb_set_auto_detach_kernel_driver(handle, 1), "enable kernel detachment");
            int configuration = 0;
            if (libusb_get_configuration(handle, &configuration) || configuration != ep.configuration)
                check(libusb_set_configuration(handle, ep.configuration), "set USB configuration");
            check(libusb_claim_interface(handle, ep.interface), "claim HCI interface");
            claimed = true;
            if (ep.alternate) check(libusb_set_interface_alt_setting(handle, ep.interface, ep.alternate), "set HCI alternate interface");
        } catch (...) { close(); throw; }
    }
    void close() {
        if (handle) {
            if (claimed) libusb_release_interface(handle, ep.interface);
            libusb_close(handle); handle = nullptr;
        }
    }
    ~Device() { close(); }
};
struct Session;
struct Input {
    Session* session;
    libusb_transfer* transfer = nullptr;
    std::vector<uint8_t> buffer;
    uint8_t type;
    bool pending = false;
    Input(Session* owner, size_t length, uint8_t packet_type) : session(owner), buffer(length), type(packet_type) {
        transfer = libusb_alloc_transfer(0);
        if (!transfer) throw std::bad_alloc();
    }
    ~Input() { libusb_free_transfer(transfer); }
};
struct Session {
    Device device;
    int socket;
    std::atomic<bool> ended{false};
    Input events{this, 1024, 4}, acl{this, 65536, 2};
    std::thread event_thread;
    explicit Session(int fd, const std::string& name) : device(name), socket(fd) {}
    static void received(libusb_transfer* transfer) noexcept {
        auto& input = *static_cast<Input*>(transfer->user_data);
        auto& self = *input.session;
        input.pending = false;
        if (transfer->status == LIBUSB_TRANSFER_COMPLETED && !self.ended) {
            try {
                // Only this event thread writes device data; packet framing is
                // preserved across arbitrary stream read/write boundaries.
                // A successful USB zero-length packet contains no HCI frame.
                // Prefixing it would corrupt framing of the following packet.
                if (transfer->actual_length > 0) {
                    send_bytes(self.socket, &input.type, 1);
                    send_bytes(self.socket, transfer->buffer, size_t(transfer->actual_length));
                }
                int result = libusb_submit_transfer(transfer);
                if (result == 0) { input.pending = true; return; }
            } catch (...) {}
        }
        self.ended = true;
        shutdown(self.socket, SHUT_RDWR);
    }
    void start() {
        libusb_fill_interrupt_transfer(events.transfer, device.handle, device.ep.events, events.buffer.data(), int(events.buffer.size()), received, &events, 0);
        libusb_fill_bulk_transfer(acl.transfer, device.handle, device.ep.acl_in, acl.buffer.data(), int(acl.buffer.size()), received, &acl, 0);
        check(libusb_submit_transfer(events.transfer), "subscribe USB events"); events.pending = true;
        try { check(libusb_submit_transfer(acl.transfer), "subscribe USB ACL"); acl.pending = true; }
        catch (...) {
            ended = true;
            libusb_cancel_transfer(events.transfer);
            while (events.pending) { timeval wait{0, 10000}; libusb_handle_events_timeout(device.context.value, &wait); }
            throw;
        }
        try {
            event_thread = std::thread([this] {
                while (!ended && !stopping) {
                    timeval wait{0, 100000};
                    int result = libusb_handle_events_timeout(device.context.value, &wait);
                    if (result < 0 && result != LIBUSB_ERROR_INTERRUPTED) ended = true;
                }
                ended = true;
                shutdown(socket, SHUT_RDWR);
                if (events.pending) libusb_cancel_transfer(events.transfer);
                if (acl.pending) libusb_cancel_transfer(acl.transfer);
                // Cancellation callbacks must finish before buffers/handles die.
                while (events.pending || acl.pending) {
                    timeval wait{0, 100000};
                    libusb_handle_events_timeout(device.context.value, &wait);
                }
            });
        } catch (...) {
            ended = true;
            libusb_cancel_transfer(events.transfer); libusb_cancel_transfer(acl.transfer);
            while (events.pending || acl.pending) { timeval wait{0, 10000}; libusb_handle_events_timeout(device.context.value, &wait); }
            throw;
        }
    }
    void host_packet(const std::vector<uint8_t>& packet) {
        int result;
        if (packet[0] == 1) {
            result = libusb_control_transfer(device.handle, 0x20, 0, 0, uint16_t(device.ep.interface),
                                             const_cast<uint8_t*>(packet.data() + 1), uint16_t(packet.size() - 1), 2000);
            check(result, "send HCI command");
            if (size_t(result) != packet.size() - 1) throw std::runtime_error("Short HCI command transfer");
        } else {
            int transferred = 0;
            result = libusb_bulk_transfer(device.handle, device.ep.acl_out, const_cast<uint8_t*>(packet.data() + 1), int(packet.size() - 1), &transferred, 2000);
            check(result, "send ACL packet");
            if (size_t(transferred) != packet.size() - 1) throw std::runtime_error("Short ACL transfer");
        }
    }
    void forward() {
        HCIFramer framer;
        uint8_t input[8192];
        while (!ended && !stopping) {
            pollfd state{socket, POLLIN, 0};
            int ready = poll(&state, 1, 200);
            if (ready < 0 && errno == EINTR) continue;
            if (ready < 0) system_error("poll HCI client");
            if (!ready) continue;
            auto count = recv(socket, input, sizeof(input), 0);
            if (count <= 0) break;
            framer.feed(input, size_t(count), [this](const auto& packet) { host_packet(packet); });
        }
    }
    ~Session() {
        ended = true;
        if (event_thread.joinable()) event_thread.join();
    }
};
void serve(uid_t uid, bool test_mode, const std::string& path) {
    auto parent = fs::path(path).parent_path();
    if (!test_mode) {
        if (geteuid() != 0 || uid == 0) throw std::runtime_error("USB service requires root and a non-root client UID");
        if (::mkdir(parent.c_str(), 0755) && errno != EEXIST) system_error("create service directory");
        struct stat info{};
        if (lstat(parent.c_str(), &info) || !S_ISDIR(info.st_mode) || info.st_uid != 0 || (info.st_mode & 0022)) throw std::runtime_error("Unsafe USB service directory");
        if (chmod(parent.c_str(), 0755)) system_error("service directory permissions");
    }
    if (path.size() >= sizeof(sockaddr_un::sun_path)) throw std::invalid_argument("USB socket path too long");
    ::unlink(path.c_str());
    FD listener(::socket(AF_UNIX, SOCK_STREAM, 0));
    if (listener.value < 0) system_error("create USB socket");
    sockaddr_un address{}; address.sun_family = AF_UNIX; std::strcpy(address.sun_path, path.c_str());
    if (bind(listener.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || chmod(path.c_str(), 0600)) system_error("bind USB socket");
    if (!test_mode && chown(path.c_str(), uid, -1)) system_error("USB socket owner");
    if (listen(listener.value, 8)) system_error("listen USB socket");
    std::atomic<bool> busy{false};
    std::thread client;
    while (!stopping) {
        pollfd state{listener.value, POLLIN, 0};
        if (poll(&state, 1, 200) <= 0) continue;
        FD accepted(accept(listener.value, nullptr, nullptr));
        if (accepted.value < 0) continue;
        bool ready = false;
        try {
            uid_t peer; gid_t group;
            if (getpeereid(accepted.value, &peer, &group) || peer != uid) throw std::runtime_error("This USB service belongs to another user");
            int yes = 1; setsockopt(accepted.value, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            auto message = Json::parse(request(accepted.value));
            if (!message.is_object() || !message.contains("transport") || !message["transport"].is_string()) throw std::invalid_argument("Only an external USB Bluetooth adapter ID is accepted");
            auto name = message["transport"].get<std::string>();
            static const std::regex pattern("usb:[0-9a-fA-F]{4}:[0-9a-fA-F]{4}");
            if (!std::regex_match(name, pattern)) throw std::invalid_argument("Only an external USB Bluetooth adapter ID is accepted");
            if (busy) throw std::runtime_error("USB adapter service is already in use");
            if (test_mode) throw std::runtime_error("USB unavailable in protocol test mode");
            if (client.joinable()) client.join();
            auto session = std::make_unique<Session>(accepted.value, name);
            send_json(accepted.value, {{"ready", true}}); ready = true;
            busy = true;
            int fd = accepted.value;
            client = std::thread([session = std::move(session), fd, &busy]() mutable {
                FD socket_owner(fd);
                try { session->start(); session->forward(); }
                catch (const std::exception& e) { std::cerr << "USB session: " << e.what() << '\n'; }
                session.reset();
                busy = false;
            });
            accepted.value = -1;
        } catch (const std::exception& e) {
            if (!ready) { try { send_json(accepted.value, {{"error", e.what()}}); } catch (...) {} }
        }
    }
    if (client.joinable()) client.join();
    ::unlink(path.c_str());
}
}
int main(int argc, char** argv) {
    signal(SIGPIPE, SIG_IGN); signal(SIGTERM, stop); signal(SIGINT, stop);
    umask(0077);
    try {
        if (argc == 2 && std::string(argv[1]) == "--self-test") {
            USBContext context;
            if (select_transport("usb:0a12:0001", Json::array({"usb:0a12:0001"}))[0] != "usb:0a12:0001") return 1;
            std::cout << "Native USB broker and libusb checks passed\n"; return 0;
        }
        if (argc == 3 && std::string(argv[1]) == "--test-socket") {
            // Unprivileged protocol tests never enumerate, open, or claim USB.
            if (geteuid() == 0) throw std::runtime_error("Protocol test mode must run unprivileged");
            serve(getuid(), true, argv[2]); return 0;
        }
        if (argc != 2) throw std::invalid_argument("Usage: raw-bluetooth-usb UID");
        std::string value = argv[1]; size_t end;
        auto uid = std::stoul(value, &end);
        if (end != value.size() || !uid || uid > UINT32_MAX) throw std::invalid_argument("Invalid client UID");
        serve(uid_t(uid), false, "/var/run/raw-bluetooth-" + value + "/usb.sock");
    } catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
