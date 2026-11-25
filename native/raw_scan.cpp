#include "usb.hpp"

#include <csignal>
#include <iomanip>
#include <iostream>
#include <memory>
#include <sstream>

namespace {
using Clock = std::chrono::steady_clock;
volatile std::sig_atomic_t interrupted = 0;

void interrupt(int) { interrupted = 1; }

std::string hex(const uint8_t* data, size_t length, char separator = 0, bool reverse = false) {
    std::ostringstream out;
    if (reverse) out << std::uppercase;
    out << std::hex << std::setfill('0');
    for (size_t i = 0; i < length; ++i) {
        if (i && separator) out << separator;
        out << std::setw(2) << unsigned(data[reverse ? length - i - 1 : i]);
    }
    return out.str();
}

void advertisements(const std::vector<uint8_t>& event) {
    if (event.size() < 4 || event[0] != 0x3e || event[2] != 2) return;
    size_t offset = 4;
    for (unsigned index = 0; index < event[3] && offset + 9 < event.size(); ++index) {
        const auto* entry = event.data() + offset;
        const size_t length = entry[8];
        if (offset + 9 + length >= event.size()) return;
        const auto* data = entry + 9;
        std::string name;
        for (size_t field = 0; field < length && data[field] && field + data[field] < length;) {
            const auto size = data[field];
            if (data[field + 1] == 8 || data[field + 1] == 9)
                name.assign(reinterpret_cast<const char*>(data + field + 2), size - 1);
            field += size + 1;
        }
        std::cout << "ADV " << hex(entry + 2, 6, ':', true) << " type=" << unsigned(entry[1])
                  << " event=" << unsigned(entry[0]) << " RSSI=" << int(int8_t(data[length]))
                  << " name=" << std::quoted(name) << " data=" << hex(data, length) << std::endl;
        offset += 10 + length;
    }
}

class Scanner {
    using Handle = std::unique_ptr<libusb_device_handle, decltype(&libusb_close)>;
    Handle handle;
    uint8_t endpoint = 0;
    bool claimed = false, detached = false, reset = false;

    static void check(int status) {
        if (status < 0) throw std::runtime_error(libusb_error_name(status));
    }

    std::vector<uint8_t> read() {
        uint8_t bytes[260];
        int length = 0;
        const int status = libusb_interrupt_transfer(handle.get(), endpoint, bytes, sizeof(bytes), &length, 500);
        if (status == LIBUSB_ERROR_TIMEOUT) return {};
        check(status);
        std::cout << "HCI RX " << hex(bytes, length) << std::endl;
        return {bytes, bytes + length};
    }

    std::vector<uint8_t> command(uint16_t opcode, std::initializer_list<uint8_t> payload = {}) {
        std::vector<uint8_t> bytes{uint8_t(opcode), uint8_t(opcode >> 8), uint8_t(payload.size())};
        bytes.insert(bytes.end(), payload);
        const uint8_t opcode_bytes[]{uint8_t(opcode >> 8), uint8_t(opcode)};
        std::cout << "HCI TX " << hex(opcode_bytes, 2) << ' '
                  << hex(bytes.data() + 3, payload.size()) << std::endl;
        const int sent = libusb_control_transfer(handle.get(), 0x20, 0, 0, 0, bytes.data(), bytes.size(), 2000);
        check(sent);
        if (size_t(sent) != bytes.size()) throw std::runtime_error("Short HCI command transfer");
        const auto deadline = Clock::now() + std::chrono::seconds(4);
        while (Clock::now() < deadline) {
            const auto event = read();
            if (event.size() < 6) continue;
            const bool complete = event[0] == 0x0e && (event[3] | event[4] << 8) == opcode;
            const bool status = event[0] == 0x0f && (event[4] | event[5] << 8) == opcode;
            if ((complete && event[5]) || (status && event[2]))
                throw std::runtime_error("HCI command rejected with status 0x" +
                                         hex(event.data() + (complete ? 5 : 2), 1));
            if (complete) return {event.begin() + 5, event.end()};
        }
        throw std::runtime_error("Timeout waiting for HCI command completion");
    }

public:
    Scanner(libusb_context* context, uint16_t vid, uint16_t pid)
        : handle(libusb_open_device_with_vid_pid(context, vid, pid), libusb_close) {
        if (!handle) throw std::runtime_error("Target USB adapter not found or could not be opened");
    }

    void scan(int seconds) {
        libusb_config_descriptor* raw_config = nullptr;
        check(libusb_get_active_config_descriptor(libusb_get_device(handle.get()), &raw_config));
        const std::unique_ptr<libusb_config_descriptor, decltype(&libusb_free_config_descriptor)>
            config(raw_config, libusb_free_config_descriptor);
        for (unsigned i = 0; i < config->bNumInterfaces; ++i) {
            const auto& interface = config->interface[i];
            for (int a = 0; a < interface.num_altsetting; ++a) {
                const auto& setting = interface.altsetting[a];
                if (setting.bInterfaceNumber != 0 || setting.bAlternateSetting != 0) continue;
                for (unsigned e = 0; e < setting.bNumEndpoints && !endpoint; ++e) {
                    const auto& candidate = setting.endpoint[e];
                    if ((candidate.bEndpointAddress & LIBUSB_ENDPOINT_IN) &&
                        (candidate.bmAttributes & LIBUSB_TRANSFER_TYPE_MASK) == LIBUSB_TRANSFER_TYPE_INTERRUPT)
                        endpoint = candidate.bEndpointAddress;
                }
            }
        }
        if (!endpoint) throw std::runtime_error("No HCI interrupt IN endpoint on interface 0");
        if (libusb_claim_interface(handle.get(), 0) < 0) {
            std::cout << "Interface occupied; attempting authorized USB driver detach." << std::endl;
            check(libusb_detach_kernel_driver(handle.get(), 0));
            detached = true;
            check(libusb_claim_interface(handle.get(), 0));
        }
        claimed = true;
        command(0x0c03);
        reset = true;
        command(0x1001);
        const auto features = command(0x1003);
        if (features.size() < 9 || !(features[5] & 0x40))
            throw std::runtime_error("Controller does not report LE support in local supported features");
        command(0x0c01, {255, 255, 255, 255, 255, 255, 255, 0x3f});
        command(0x2001, {0x1f, 0, 0, 0, 0, 0, 0, 0});
        command(0x200b, {1, 0x10, 0, 0x10, 0, 0, 0});
        command(0x200c, {1, 0});
        std::cout << "Direct HCI scan active for " << seconds << "s. Keep M196 blinking." << std::endl;
        const auto deadline = Clock::now() + std::chrono::seconds(seconds);
        while (!interrupted && Clock::now() < deadline) advertisements(read());
    }

    ~Scanner() {
        if (reset) {
            for (const auto opcode : {0x200c, 0x0c03}) {
                try {
                    if (opcode == 0x200c) command(opcode, {0, 0});
                    else command(opcode);
                } catch (const std::exception& error) {
                    std::cerr << "Controller cleanup: " << error.what() << '\n';
                }
            }
        }
        if (claimed) libusb_release_interface(handle.get(), 0);
        if (detached && libusb_attach_kernel_driver(handle.get(), 0) < 0)
            std::cerr << "Reattach failed. Unplug/replug the USB adapter to restore macOS ownership.\n";
    }
};
}

int main(int argc, char** argv) {
    if (argc != 4) return 2;
    std::signal(SIGINT, interrupt);
    try {
        rawbt::USBContext context;
        Scanner scanner(context.value, std::stoi(argv[1]), std::stoi(argv[2]));
        scanner.scan(std::stoi(argv[3]));
    } catch (const std::exception& error) {
        std::cerr << "STOPPED: " << error.what() << '\n';
        return 1;
    }
}
