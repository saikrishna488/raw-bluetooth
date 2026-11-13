#pragma once
#include "vendor/nlohmann/json.hpp"
#include <algorithm>
#include <chrono>
#include <cerrno>
#include <cctype>
#include <cstring>
#include <cmath>
#include <limits>
#include <filesystem>
#include <fstream>
#include <fcntl.h>
#include <regex>
#include <set>
#include <stdexcept>
#include <string>
#include <system_error>
#include <unistd.h>
#include <sys/stat.h>

namespace rawbt {
using Json = nlohmann::ordered_json;
namespace fs = std::filesystem;
inline double now() {
    return std::chrono::duration<double>(std::chrono::system_clock::now().time_since_epoch()).count();
}
inline void system_error(const std::string& message) { throw std::system_error(errno, std::generic_category(), message); }
struct FD {
    int value = -1;
    explicit FD(int fd = -1) : value(fd) {}
    FD(const FD&) = delete;
    FD& operator=(const FD&) = delete;
    ~FD() { if (value >= 0) ::close(value); }
};
inline void write_all(int fd, const std::string& bytes) {
    size_t offset = 0;
    while (offset < bytes.size()) {
        auto n = ::write(fd, bytes.data() + offset, bytes.size() - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) system_error("write");
        offset += size_t(n);
    }
}
inline std::string read_file(const fs::path& path, size_t limit = 16 * 1024 * 1024) {
    FD fd(::open(path.c_str(), O_RDONLY | O_CLOEXEC | O_NOFOLLOW));
    if (fd.value < 0) system_error("open " + path.filename().string());
    struct stat info{};
    if (fstat(fd.value, &info)) system_error("stat");
    if (!S_ISREG(info.st_mode) || info.st_size < 0 || uint64_t(info.st_size) > limit)
        throw std::invalid_argument("Invalid or oversized file");
    std::string bytes;
    char buffer[8192];
    for (;;) {
        auto n = ::read(fd.value, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) system_error("read");
        if (!n) return bytes;
        if (bytes.size() + size_t(n) > limit) throw std::invalid_argument("Oversized file");
        bytes.append(buffer, size_t(n));
    }
}
inline void atomic_write(const fs::path& path, const std::string& bytes) {
    fs::path parent = path.parent_path().empty() ? fs::path(".") : path.parent_path();
    fs::create_directories(parent);
    std::string temporary = (parent / ".raw-bt-XXXXXX").string();
    FD fd(::mkstemp(temporary.data()));
    if (fd.value < 0) system_error("create private temporary file");
    try {
        if (fchmod(fd.value, 0600)) system_error("chmod");
        if (geteuid() == 0) {
            struct stat owner{};
            if (::stat(parent.c_str(), &owner) || fchown(fd.value, owner.st_uid, owner.st_gid)) system_error("chown");
        }
        write_all(fd.value, bytes);
        if (fsync(fd.value) || ::rename(temporary.c_str(), path.c_str())) system_error("commit private state");
    } catch (...) { ::unlink(temporary.c_str()); throw; }
}
inline Json read_json(const fs::path& path) { return Json::parse(read_file(path)); }
inline int appearance(const Json& value) {
    try {
        if (value.is_number()) {
            double number = value.get<double>();
            if (std::isfinite(number) && number >= std::numeric_limits<int>::min() && number <= std::numeric_limits<int>::max()) return int(number);
            return 0;
        }
        if (value.is_boolean()) return value.get<bool>() ? 1 : 0;
        if (value.is_string()) {
            const auto text = value.get<std::string>();
            size_t end = 0;
            int result = std::stoi(text, &end);
            if (end == text.size()) return result;
        }
    } catch (const std::exception&) {}
    return 0;
}
inline bool truth(const Json& value) {
    if (value.is_null()) return false;
    if (value.is_boolean()) return value.get<bool>();
    if (value.is_number()) return value.get<double>() != 0;
    return !value.empty();
}
inline std::string lower(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) { return char(std::tolower(c)); });
    return value;
}
inline bool audio_name(const std::string& name) {
    auto value = lower(name);
    for (auto word : {"airpod", "headphone", "headset", "earbud", "speaker", "buds"})
        if (value.find(word) != std::string::npos) return true;
    return false;
}
inline bool valid_address(const std::string& value) {
    static const std::regex pattern("(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}(?:/P)?");
    return std::regex_match(value, pattern);
}
inline Json saved_load(const fs::path& path) {
    Json data;
    try { data = read_json(path); } catch (const std::exception&) { return Json::object(); }
    Json result = Json::object();
    if (!data.is_object()) return result;
    for (auto item = data.begin(); item != data.end(); ++item) {
        const auto& record = item.value();
        if (!valid_address(item.key()) || !record.is_object()) continue;
        auto category = record.value("category", Json());
        if (category != "Mouse" && category != "Keyboard") continue;
        auto name = record.value("name", Json(""));
        std::string text = name.is_string() ? name.get<std::string>() : name.dump();
        // Truncate by UTF-8 characters, never in the middle of a code point.
        size_t end = 0, count = 0;
        while (end < text.size() && count < 255) {
            ++end;
            while (end < text.size() && (uint8_t(text[end]) & 0xc0) == 0x80) ++end;
            ++count;
        }
        result[item.key()] = {{"address", item.key()}, {"name", text.substr(0, end)}, {"category", category},
                              {"appearance", appearance(record.value("appearance", Json(0)))},
                              {"auto_reconnect", truth(record.value("auto_reconnect", Json(true)))}};
    }
    return result;
}
inline Json remembered(const Json& devices, const Json& info, const Json& enabled) {
    auto key = info.at("address").get<std::string>();
    auto previous = devices.value(key, Json::object());
    Json record;
    for (auto name : {"address", "name", "category", "appearance"})
        record[name] = info.value(name, previous.value(name, Json("")));
    record["appearance"] = appearance(record["appearance"]);
    record["auto_reconnect"] = enabled.is_null() ? previous.value("auto_reconnect", Json(true)) : Json(truth(enabled));
    return record;
}
inline Json advertisement(const Json& args) {
    auto previous = args.value("previous", Json::object());
    auto name = args.value("name", std::string());
    if (name.empty()) name = previous.value("name", std::string());
    int app = appearance(previous.value("appearance", Json(0)));
    auto raw = args.at("raw").get<std::vector<uint8_t>>();
    for (size_t pos = 0; pos < raw.size();) {
        auto size = raw[pos];
        if (!size || pos + size >= raw.size()) break;
        if (raw[pos + 1] == 0x19 && size >= 3) app = raw[pos + 2] | (raw[pos + 3] << 8);
        pos += size + 1;
    }
    auto lname = lower(name);
    std::string category = app == 0x3c2 || lname.find("m196") != std::string::npos || lname.find("mouse") != std::string::npos ? "Mouse" :
        app == 0x3c1 || lname.find("k250") != std::string::npos || lname.find("keyboard") != std::string::npos ? "Keyboard" :
        audio_name(name) || previous.value("category", std::string()) == "Audio" ? "Audio" : "BLE device";
    bool classic = previous.value("classic_available", false);
    return {{"address", args.at("address")}, {"name", name}, {"rssi", args.at("rssi")},
            {"connectable", args.value("connectable", false) || classic || (args.value("scan_response", false) && previous.value("connectable", false))},
            {"classic_available", classic}, {"appearance", app}, {"category", category}, {"last_seen", args.value("now", now())}};
}
inline Json command(const fs::path& path, const Json& last) {
    Json value;
    try { value = Json::parse(read_file(path, 4096)); }
    catch (const std::exception&) { return nullptr; }
    static const std::set<std::string> actions = {"scan", "pause", "connect", "disconnect", "stop", "remember", "forget", "audio_test", "audio_play", "audio_system", "audio_disconnect"};
    if (!value.is_object() || !value.contains("id") || !value["id"].is_string() || value["id"] == last ||
        !value.contains("action") || !value["action"].is_string() || !actions.count(value["action"].get<std::string>())) return nullptr;
    return value;
}
inline Json reconnect(const Json& args) {
    Json result = Json::array();
    double timestamp = args.at("now");
    const auto& saved = args.at("saved");
    const auto& devices = args.at("devices");
    for (auto i = saved.begin(); i != saved.end(); ++i) {
        auto key = i.key();
        auto paused = args.at("paused").get<std::vector<std::string>>();
        auto tasks = args.at("tasks").get<std::vector<std::string>>();
        if (i.value().value("auto_reconnect", true) && std::find(paused.begin(), paused.end(), key) == paused.end() &&
            std::find(tasks.begin(), tasks.end(), key) == tasks.end() && timestamp >= args.at("retry_at").value(key, 0.0) &&
            devices.value(key, Json::object()).value("last_seen", 0.0) > timestamp - 15) result.push_back(key);
    }
    return result;
}
inline Json select_transport(const std::string& request, const Json& adapters) {
    if (request != "auto") {
        if (request.rfind("usb:", 0) == 0) {
            static const std::regex pattern("usb:[0-9a-fA-F]{4}:[0-9a-fA-F]{4}");
            if (!std::regex_match(request, pattern)) throw std::invalid_argument("Use usb:VID:PID, for example usb:0a12:0001.");
            auto normalized = lower(request);
            if (std::find(adapters.begin(), adapters.end(), normalized) == adapters.end())
                throw std::invalid_argument("Selected USB adapter is unavailable, internal, duplicated, or lacks a standard Bluetooth HCI interface.");
            return Json::array({normalized, false});
        }
        return Json::array({request, false});
    }
    if (adapters.empty()) throw std::invalid_argument("No available external USB Bluetooth HCI adapter found. Connect a dongle with standard HCI firmware; firmware-only devices are not supported.");
    if (adapters.size() > 1) throw std::invalid_argument("Multiple USB Bluetooth adapters found. Select a USB ID in Settings or use --transport: " + adapters.dump());
    return Json::array({adapters[0], false});
}
struct Journal {
    FD fd;
    Json devices = Json::object(), saved = Json::object(), passkeys = Json::object();
    std::set<std::string> connected;
    std::string connecting;
    size_t limit;
    explicit Journal(const fs::path& path, size_t max_bytes = 2 * 1024 * 1024) :
        fd(::open(path.c_str(), O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0644)), limit(max_bytes) {
        if (fd.value < 0) system_error("open event journal");
        if (fchmod(fd.value, 0644)) system_error("event permissions");
    }
    void line(const std::string& state, Json details) {
        details["state"] = state;
        details["time"] = now();
        write_all(fd.value, details.dump(-1, ' ', false, Json::error_handler_t::replace) + "\n");
    }
    void emit(const std::string& state, const Json& details) {
        if (fd.value < 0) throw std::runtime_error("Event journal is closed");
        auto key = details.value("address", std::string());
        if (state == "device") devices[key] = details;
        if (state == "device_removed") devices.erase(key);
        if (state == "saved") saved[key] = details;
        if (state == "forgotten") { saved.erase(key); devices.erase(key); }
        if (state == "connecting") connecting = key;
        if (state == "connected") connected.insert(key);
        if (state == "disconnected") connected.erase(key);
        if (state == "connected" || state == "disconnected" || state == "error") { if (connecting == key) connecting.clear(); }
        if (state == "passkey") passkeys[key] = details.at("code");
        if (state == "connected" || state == "disconnected" || state == "discovering" || state == "error") passkeys.erase(key);
        struct stat info{};
        if (fstat(fd.value, &info)) system_error("stat event journal");
        if (uint64_t(info.st_size) > limit) {
            if (ftruncate(fd.value, 0)) system_error("rotate event journal");
            for (const auto& record : devices) line("device", record);
            for (const auto& record : saved) line("saved", record);
            for (const auto& address : connected) line("connected", {{"address", address}});
            if (!connecting.empty()) line("connecting", {{"address", connecting}});
            for (auto i = passkeys.begin(); i != passkeys.end(); ++i) line("passkey", {{"address", i.key()}, {"code", i.value()}});
        }
        line(state, details);
    }
};
} // namespace rawbt
