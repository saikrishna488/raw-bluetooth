#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include "core.hpp"
#include "usb.hpp"
#include "pointer.hpp"
#include "sender.hpp"
#include "hci.hpp"
#include <cstdlib>

using namespace rawbt;
namespace {
Json dispatch(const std::string& op, const Json& a) {
    if (op == "hci_packets") {
        HCIFramer framer;
        Json packets = Json::array();
        for (const auto& chunk : a) {
            auto bytes = chunk.get<std::vector<uint8_t>>();
            framer.feed(bytes.data(), bytes.size(), [&](const auto& packet) { packets.push_back(packet); });
        }
        return packets;
    }
    if (op == "advertisement") return advertisement(a);
    if (op == "command") return command(a.at("path"), a.at("last_id"));
    if (op == "reconnect") return reconnect(a);
    if (op == "saved_load") return saved_load(a.at("path"));
    if (op == "remember") return remembered(a.at("devices"), a.at("info"), a.at("enabled"));
    if (op == "save") { atomic_write(a.at("path"), a.at("data").dump(2)); return nullptr; }
    if (op == "diagnostic") { atomic_write(a.at("path"), a.at("text")); return nullptr; }
    if (op == "appearance") return appearance(a);
    if (op == "discover_adapters") return discover_adapters();
    if (op == "service_installed") {
        auto path = a.at("path").get<std::string>();
        struct stat directory{}, endpoint{};
        return lstat(fs::path(path).parent_path().c_str(), &directory) == 0 &&
            lstat(path.c_str(), &endpoint) == 0 && S_ISDIR(directory.st_mode) && directory.st_uid == 0 &&
            !(directory.st_mode & 0022) && S_ISSOCK(endpoint.st_mode) && endpoint.st_uid == getuid() && !(endpoint.st_mode & 0077);
    }
    if (op == "external_usb_ids") {
        Json result = Json::array();
        for (auto id : external_ids()) result.push_back({id.first, id.second});
        return result;
    }
    if (op == "topology") {
        std::set<USBID> allowed, denied;
        for (const auto& node : a) {
            if (!node.contains("idVendor") || !node.contains("idProduct")) continue;
            USBID id{node.at("idVendor"), node.at("idProduct")};
            bool external = node.value("Built-In", Json()) == false && lower(node.value("non-removable", std::string())) == "no";
            (external ? allowed : denied).insert(id);
        }
        for (auto id : denied) allowed.erase(id);
        allowed.erase({0x04ca, 0x3018});
        Json result = Json::array();
        for (auto id : allowed) result.push_back({id.first, id.second});
        return result;
    }
    if (op == "hci_interface") {
        for (const auto& interface : a) {
            if (interface.at("class") != Json::array({0xe0, 1, 1})) continue;
            bool events = false, input = false, output = false;
            for (const auto& ep : interface.at("endpoints")) {
                int kind = ep.at(0).get<int>() & 3, address = ep.at(1);
                events |= kind == 3 && (address & 0x80);
                input |= kind == 2 && (address & 0x80);
                output |= kind == 2 && !(address & 0x80);
            }
            if (events && input && output) return true;
        }
        return false;
    }
    if (op == "select_transport") return select_transport(a.at("request"), a.at("adapters"));
    if (op == "expire") {
        Json result = Json::array();
        for (auto i = a.at("devices").begin(); i != a.at("devices").end(); ++i)
            if (!a.at("saved").contains(i.key()) && a.at("now").get<double>() - i.value().value("last_seen", 0.0) > 30) result.push_back(i.key());
        return result;
    }
    if (op == "inquiry") {
        auto name = a.at("name").get<std::string>();
        if (((a.at("class").get<int>() >> 8) & 31) != 4 && !audio_name(name)) return nullptr;
        return {{"address", a.at("address")}, {"name", name}, {"rssi", a.at("rssi")}, {"connectable", true},
                {"classic_available", true}, {"appearance", 0}, {"category", "Audio"}, {"last_seen", a.at("now")}};
    }
    if (op == "migrate_bonds") {
        fs::path path = a.at("path");
        if (!fs::exists(path)) return nullptr;
        auto database = read_json(path);
        auto target = database.value("RawBluetooth", Json::object());
        bool changed = false;
        for (const auto& peer : a.at("peers")) {
            auto key = peer.get<std::string>();
            if (target.contains(key)) continue;
            for (auto i = database.begin(); i != database.end(); ++i) {
                if (i.key() != "RawBluetooth" && i.value().is_object() && i.value().contains(key)) {
                    target[key] = i.value()[key]; changed = true; break;
                }
            }
        }
        if (changed) {
            auto backup = path.parent_path() / "driver-bonds.pre-dual-adapter.json";
            if (!fs::exists(backup)) atomic_write(backup, read_file(path));
            database["RawBluetooth"] = target;
            atomic_write(path, database.dump(2));
        }
        return nullptr;
    }
    if (op == "forget_bond") {
        fs::path path = a.at("path");
        Json database;
        try { database = read_json(path); } catch (const std::exception&) { return false; }
        bool changed = false;
        for (auto& record : database) if (record.is_object()) changed |= record.erase(a.at("peer").get<std::string>()) > 0;
        if (changed) atomic_write(path, database.dump(2));
        return changed;
    }
    if (op == "identity") {
        fs::path path = a.at("path");
        if (!fs::exists(path)) {
            uint8_t bytes[22]; arc4random_buf(bytes, sizeof(bytes)); bytes[0] |= 0xc0;
            char address[18];
            snprintf(address, sizeof(address), "%02X:%02X:%02X:%02X:%02X:%02X", bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5]);
            std::string irk;
            const char* hex = "0123456789abcdef";
            for (int i = 6; i < 22; ++i) { irk += hex[bytes[i] >> 4]; irk += hex[bytes[i] & 15]; }
            atomic_write(path, Json({{"address", address}, {"irk", irk}}).dump());
        }
        return read_json(path);
    }
    if (op == "clamp_pointer") {
        auto point = clamp_pointer({a.at("x"), a.at("y")}, a.at("displays"));
        return Json::array({point.x, point.y});
    }
    if (op == "request_accessibility") {
        const void* keys[] = { kAXTrustedCheckOptionPrompt };
        const void* values[] = { kCFBooleanTrue };
        auto options = CFDictionaryCreate(nullptr, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        bool allowed = AXIsProcessTrustedWithOptions(options);
        CFRelease(options);
        return allowed;
    }
    throw std::invalid_argument("Unknown native operation: " + op);
}
PyObject* error() {
    try { throw; }
    catch (const std::system_error& e) { PyErr_SetString(PyExc_OSError, e.what()); }
    catch (const std::invalid_argument& e) { PyErr_SetString(PyExc_ValueError, e.what()); }
    catch (const nlohmann::detail::exception& e) { PyErr_SetString(PyExc_ValueError, e.what()); }
    catch (const std::exception& e) { PyErr_SetString(PyExc_RuntimeError, e.what()); }
    return nullptr;
}
PyObject* execute(PyObject*, PyObject* args) {
    const char *op, *payload;
    Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "ss#", &op, &payload, &length)) return nullptr;
    try {
        auto result = dispatch(op, Json::parse(payload, payload + length)).dump(-1, ' ', false, Json::error_handler_t::replace);
        return PyUnicode_FromStringAndSize(result.data(), Py_ssize_t(result.size()));
    } catch (...) { return error(); }
}
constexpr const char* journal_name = "raw_bluetooth.journal";
void journal_destroy(PyObject* capsule) { delete static_cast<Journal*>(PyCapsule_GetPointer(capsule, journal_name)); }
PyObject* journal_create(PyObject*, PyObject* args) {
    const char* path; unsigned long limit = 2 * 1024 * 1024;
    if (!PyArg_ParseTuple(args, "s|k", &path, &limit)) return nullptr;
    try { return PyCapsule_New(new Journal(path, limit), journal_name, journal_destroy); } catch (...) { return error(); }
}
PyObject* journal_emit(PyObject*, PyObject* args) {
    PyObject* capsule; const char *state, *payload;
    if (!PyArg_ParseTuple(args, "Oss", &capsule, &state, &payload)) return nullptr;
    auto journal = static_cast<Journal*>(PyCapsule_GetPointer(capsule, journal_name));
    if (!journal) return nullptr;
    try { journal->emit(state, Json::parse(payload)); Py_RETURN_NONE; } catch (...) { return error(); }
}
PyObject* journal_close(PyObject*, PyObject* capsule) {
    auto journal = static_cast<Journal*>(PyCapsule_GetPointer(capsule, journal_name));
    if (!journal) return nullptr;
    if (journal->fd.value >= 0) { ::close(journal->fd.value); journal->fd.value = -1; }
    Py_RETURN_NONE;
}
constexpr const char* pointer_name = "raw_bluetooth.pointer";
void pointer_destroy(PyObject* capsule) { delete static_cast<Pointer*>(PyCapsule_GetPointer(capsule, pointer_name)); }
PyObject* pointer_create(PyObject*, PyObject*) {
    try { return PyCapsule_New(new Pointer(), pointer_name, pointer_destroy); } catch (...) { return error(); }
}
PyObject* pointer_apply(PyObject*, PyObject* args) {
    PyObject* capsule; const char* payload;
    if (!PyArg_ParseTuple(args, "Os", &capsule, &payload)) return nullptr;
    auto pointer = static_cast<Pointer*>(PyCapsule_GetPointer(capsule, pointer_name));
    if (!pointer) return nullptr;
    try { pointer->apply(Json::parse(payload)); Py_RETURN_NONE; } catch (...) { return error(); }
}
PyObject* pointer_release(PyObject*, PyObject* capsule) {
    auto pointer = static_cast<Pointer*>(PyCapsule_GetPointer(capsule, pointer_name));
    if (!pointer) return nullptr;
    try { pointer->release(); Py_RETURN_NONE; } catch (...) { return error(); }
}
PyObject* run_pointer_bridge(PyObject*, PyObject* args) {
    const char* path; double duration;
    if (!PyArg_ParseTuple(args, "sd", &path, &duration)) return nullptr;
    std::exception_ptr failure;
    Py_BEGIN_ALLOW_THREADS
    try { pointer_bridge(path, duration); } catch (...) { failure = std::current_exception(); }
    Py_END_ALLOW_THREADS
    if (failure) { try { std::rethrow_exception(failure); } catch (...) { return error(); } }
    Py_RETURN_NONE;
}
constexpr const char* sender_name = "raw_bluetooth.sender";
void sender_destroy(PyObject* capsule) { delete static_cast<DatagramSender*>(PyCapsule_GetPointer(capsule, sender_name)); }
PyObject* sender_create(PyObject*, PyObject* args) {
    const char* path;
    if (!PyArg_ParseTuple(args, "s", &path)) return nullptr;
    try { return PyCapsule_New(new DatagramSender(path), sender_name, sender_destroy); } catch (...) { return error(); }
}
PyObject* sender_enqueue(PyObject*, PyObject* args) {
    PyObject* capsule; const char* payload; Py_ssize_t length;
    if (!PyArg_ParseTuple(args, "Os#", &capsule, &payload, &length)) return nullptr;
    auto sender = static_cast<DatagramSender*>(PyCapsule_GetPointer(capsule, sender_name));
    if (!sender) return nullptr;
    try { sender->enqueue(std::string(payload, size_t(length))); Py_RETURN_NONE; } catch (...) { return error(); }
}
PyObject* sender_drain(PyObject*, PyObject* args) {
    PyObject* capsule; double seconds = 1;
    if (!PyArg_ParseTuple(args, "O|d", &capsule, &seconds)) return nullptr;
    auto sender = static_cast<DatagramSender*>(PyCapsule_GetPointer(capsule, sender_name));
    if (!sender) return nullptr;
    bool idle;
    Py_BEGIN_ALLOW_THREADS
    idle = sender->drain(seconds);
    Py_END_ALLOW_THREADS
    return PyBool_FromLong(idle);
}
PyObject* sender_close(PyObject*, PyObject* capsule) {
    auto sender = static_cast<DatagramSender*>(PyCapsule_GetPointer(capsule, sender_name));
    if (!sender) return nullptr;
    Py_BEGIN_ALLOW_THREADS
    sender->close();
    Py_END_ALLOW_THREADS
    Py_RETURN_NONE;
}
PyMethodDef methods[] = {
    {"execute", execute, METH_VARARGS, nullptr},
    {"journal_create", journal_create, METH_VARARGS, nullptr}, {"journal_emit", journal_emit, METH_VARARGS, nullptr}, {"journal_close", journal_close, METH_O, nullptr},
    {"pointer_create", pointer_create, METH_NOARGS, nullptr}, {"pointer_apply", pointer_apply, METH_VARARGS, nullptr}, {"pointer_release", pointer_release, METH_O, nullptr},
    {"pointer_bridge", run_pointer_bridge, METH_VARARGS, nullptr},
    {"sender_create", sender_create, METH_VARARGS, nullptr}, {"sender_enqueue", sender_enqueue, METH_VARARGS, nullptr},
    {"sender_drain", sender_drain, METH_VARARGS, nullptr}, {"sender_close", sender_close, METH_O, nullptr},
    {nullptr, nullptr, 0, nullptr}
};
PyModuleDef module = {PyModuleDef_HEAD_INIT, "_driver_native", nullptr, -1, methods};
}
PyMODINIT_FUNC PyInit__driver_native() { return PyModule_Create(&module); }
