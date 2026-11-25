#pragma once

#include <Python.h>

// Discovery records are also consumed by Python session orchestration. Iterate
// the original mappings in place to avoid copying them through JSON every tick.
namespace rawbt::discovery {
inline bool number(PyObject* record, const char* key, double& value) {
    if (record && !PyDict_Check(record)) {
        PyErr_SetString(PyExc_TypeError, "Discovery record must be a dictionary");
        return false;
    }
    auto* item = record ? PyDict_GetItemString(record, key) : nullptr;
    value = item ? PyFloat_AsDouble(item) : 0;
    return !PyErr_Occurred();
}

inline PyObject* touch_advertisement(PyObject*, PyObject* args) {
    PyObject *devices, *emissions, *key;
    double monotonic, wall;
    if (!PyArg_ParseTuple(args, "O!O!Udd", &PyDict_Type, &devices, &PyDict_Type, &emissions,
                          &key, &monotonic, &wall)) return nullptr;
    auto* record = PyDict_GetItemWithError(devices, key);
    auto* emission = PyDict_GetItemWithError(emissions, key);
    if (PyErr_Occurred()) return nullptr;
    const double last = emission ? PyFloat_AsDouble(emission) : 0;
    if (PyErr_Occurred()) return nullptr;
    if (!record || monotonic - last > 1) Py_RETURN_FALSE;
    auto* timestamp = PyFloat_FromDouble(wall);
    if (!timestamp) return nullptr;
    const auto status = PyDict_SetItemString(record, "last_seen", timestamp);
    Py_DECREF(timestamp);
    if (status < 0) return nullptr;
    Py_RETURN_TRUE;
}

inline PyObject* expire_devices(PyObject*, PyObject* args) {
    PyObject *devices, *saved;
    double now;
    if (!PyArg_ParseTuple(args, "O!O!d", &PyDict_Type, &devices, &PyDict_Type, &saved, &now))
        return nullptr;
    auto* result = PyList_New(0);
    if (!result) return nullptr;
    Py_ssize_t position = 0;
    PyObject *key, *record;
    while (PyDict_Next(devices, &position, &key, &record)) {
        const int keep = PyDict_Contains(saved, key);
        double seen;
        if (keep < 0 || (!keep && (!number(record, "last_seen", seen) ||
                                   (now - seen > 30 && PyList_Append(result, key) < 0)))) {
            Py_DECREF(result);
            return nullptr;
        }
    }
    return result;
}

inline PyObject* reconnect_candidates(PyObject*, PyObject* args) {
    PyObject *devices, *saved, *paused, *tasks, *retry;
    double now;
    if (!PyArg_ParseTuple(args, "O!O!O!O!O!d", &PyDict_Type, &devices, &PyDict_Type, &saved,
                          &PySet_Type, &paused, &PyDict_Type, &tasks, &PyDict_Type, &retry, &now))
        return nullptr;
    auto* result = PyList_New(0);
    if (!result) return nullptr;
    Py_ssize_t position = 0;
    PyObject *key, *record;
    while (PyDict_Next(saved, &position, &key, &record)) {
        if (!PyDict_Check(record)) {
            PyErr_SetString(PyExc_TypeError, "Saved device must be a dictionary");
            break;
        }
        auto* enabled = PyDict_GetItemString(record, "auto_reconnect");
        const int allowed = enabled ? PyObject_IsTrue(enabled) : 1;
        const int suspended = PySet_Contains(paused, key);
        const int connected = PyDict_Contains(tasks, key);
        if (allowed < 0 || suspended < 0 || connected < 0) break;
        if (!allowed || suspended || connected) continue;
        auto* retry_at = PyDict_GetItemWithError(retry, key);
        const double deadline = retry_at ? PyFloat_AsDouble(retry_at) : 0;
        auto* device = PyDict_GetItemWithError(devices, key);
        double seen;
        if (PyErr_Occurred() || !number(device, "last_seen", seen)) break;
        if (now >= deadline && seen > now - 15 && PyList_Append(result, key) < 0) break;
    }
    if (!PyErr_Occurred()) return result;
    Py_DECREF(result);
    return nullptr;
}
}
