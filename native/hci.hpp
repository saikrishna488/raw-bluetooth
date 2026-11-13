#pragma once
#include <cstdint>
#include <stdexcept>
#include <vector>

namespace rawbt {
class HCIFramer {
    std::vector<uint8_t> buffer;
public:
    template<class Output> void feed(const uint8_t* data, size_t length, Output output) {
        if (length) buffer.insert(buffer.end(), data, data + length);
        size_t offset = 0;
        while (offset < buffer.size()) {
            uint8_t type = buffer[offset];
            if (type != 1 && type != 2) throw std::invalid_argument("Only HCI commands and ACL packets are supported");
            size_t header = type == 1 ? 4 : 5;
            if (buffer.size() - offset < header) break;
            size_t body = type == 1 ? buffer[offset + 3] : size_t(buffer[offset + 3]) | size_t(buffer[offset + 4]) << 8;
            if (buffer.size() - offset < header + body) break;
            output(std::vector<uint8_t>(buffer.begin() + offset, buffer.begin() + offset + header + body));
            offset += header + body;
        }
        buffer.erase(buffer.begin(), buffer.begin() + offset);
        if (buffer.size() > 65540) throw std::invalid_argument("Oversized HCI packet");
    }
};
}
