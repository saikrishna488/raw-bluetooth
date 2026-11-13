#include "core.hpp"
#include "hci.hpp"
#include <cassert>
#include <iostream>

using namespace rawbt;
int main() {
    std::vector<uint8_t> command{1, 3, 12, 0}, acl{2, 1, 0, 3, 0, 8, 9, 10};
    auto both = command;
    both.insert(both.end(), acl.begin(), acl.end());
    for (size_t split = 0; split <= both.size(); ++split) {
        HCIFramer framer;
        std::vector<std::vector<uint8_t>> received;
        auto output = [&](const auto& packet) { received.push_back(packet); };
        framer.feed(both.data(), split, output);
        framer.feed(both.data() + split, both.size() - split, output);
        assert((received == std::vector<std::vector<uint8_t>>{command, acl}));
    }
    {
        HCIFramer framer;
        std::vector<std::vector<uint8_t>> received;
        for (const auto& byte : both) framer.feed(&byte, 1, [&](const auto& packet) { received.push_back(packet); });
        assert(received.size() == 2);
    }
    for (uint8_t invalid : {0, 3, 4, 5, 255}) {
        bool rejected = false;
        try { HCIFramer{}.feed(&invalid, 1, [](auto) {}); } catch (const std::invalid_argument&) { rejected = true; }
        assert(rejected);
    }
    assert(valid_address("01:02:03:04:05:06/P"));
    assert(!valid_address("01:02:03:04:05:06/../file"));
    assert(appearance("961") == 961 && appearance("961bad") == 0);
    assert(select_transport("usb:0A12:0001", Json::array({"usb:0a12:0001"}))[0] == "usb:0a12:0001");
    auto info = advertisement({{"name", "mouse"}, {"raw", Json::array({3, 0x19, 0xc2, 3})},
                               {"address", "01:02:03:04:05:06"}, {"rssi", -20}, {"connectable", true}});
    assert(info["appearance"] == 962 && info["category"] == "Mouse");
    std::cout << "Native core packet framing and policy checks passed\n";
}
