#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include "hid.hpp"
#include <map>
#include <vector>
#include <stdexcept>
#include <algorithm>

namespace {
using namespace rawbt::hid;
void destroy(PyObject* obj) { delete static_cast<Parser*>(PyCapsule_GetPointer(obj, capsule_name)); }
Parser* get(PyObject* obj) { return static_cast<Parser*>(PyCapsule_GetPointer(obj, capsule_name)); }
PyObject* create(PyObject*, PyObject* args) {
    const char* data; Py_ssize_t size;
    if(!PyArg_ParseTuple(args,"y#",&data,&size)) return nullptr;
    try { return PyCapsule_New(new Parser(parse(reinterpret_cast<const uint8_t*>(data),size)),capsule_name,destroy); }
    catch(const std::exception& e) { PyErr_SetString(PyExc_ValueError,e.what()); return nullptr; }
}
PyObject* metadata(PyObject*, PyObject* capsule) {
    auto* p=get(capsule); if(!p) return nullptr;
    PyObject* result=PyDict_New(); if(!result) return nullptr;
    for(const auto& entry:p->reports) {
        PyObject* fields=PyList_New(0);
        for(const auto& f:entry.second.fields) {
            PyObject* item=Py_BuildValue("(IIIIiii)",f.offset,f.size,f.page,f.usage,int(f.sign),int(f.relative),int(f.variable));
            if(!item || PyList_Append(fields,item)<0) { Py_XDECREF(item); Py_DECREF(fields); Py_DECREF(result); return nullptr; }
            Py_DECREF(item);
        }
        PyObject* key=PyLong_FromUnsignedLong(entry.first);
        PyObject* item=Py_BuildValue("(IN)",(entry.second.bits+7)/8,fields);
        if(!key || !item || PyDict_SetItem(result,key,item)<0) { Py_XDECREF(key); Py_XDECREF(item); Py_DECREF(result); return nullptr; }
        Py_DECREF(key); Py_DECREF(item);
    }
    return result;
}
PyObject* usage_set(const std::set<uint32_t>& usages) {
    PyObject* result = PySet_New(nullptr);
    if (!result) return nullptr;
    for (auto usage : usages) {
        PyObject* value = PyLong_FromUnsignedLong(usage);
        const int status = value ? PySet_Add(result, value) : -1;
        Py_XDECREF(value);
        if (status < 0) { Py_DECREF(result); return nullptr; }
    }
    return result;
}

PyObject* decode(PyObject*, PyObject* args) {
    PyObject* capsule;
    unsigned id;
    const char* bytes;
    Py_ssize_t length;
    int keyboard;
    if (!PyArg_ParseTuple(args, "OIy#p", &capsule, &id, &bytes, &length, &keyboard)) return nullptr;
    auto* parser = get(capsule);
    if (!parser) return nullptr;
    try {
        auto report = rawbt::hid::decode(*parser, id, reinterpret_cast<const uint8_t*>(bytes), length, keyboard);
        if (report.rollover) Py_RETURN_NONE;
        if (keyboard) {
            PyObject* keys = usage_set(report.keyboard.keys);
            if (!keys) return nullptr;
            PyObject* consumers = usage_set(report.keyboard.consumers);
            if (!consumers) { Py_DECREF(keys); return nullptr; }
            return Py_BuildValue("(NN)", keys, consumers);
        }
        PyObject* result = PyDict_New();
        if (!result) return nullptr;
        const char* axes[] = {"x", "y", "wheel", "pan"};
        for (int axis = 0; axis < 4; ++axis) {
            if (!(report.axis_mask & (1 << axis))) continue;
            PyObject* value = PyLong_FromLongLong(report.axes[axis]);
            const int status = value ? PyDict_SetItemString(result, axes[axis], value) : -1;
            Py_XDECREF(value);
            if (status < 0) { Py_DECREF(result); return nullptr; }
        }
        for (int button = 0; button < 8; ++button) {
            const int mask = 1 << button;
            if (!(report.button_mask & mask)) continue;
            char name[] = "button1";
            name[6] += button;
            if (PyDict_SetItemString(result, name, report.buttons & mask ? Py_True : Py_False) < 0) {
                Py_DECREF(result);
                return nullptr;
            }
        }
        return result;
    } catch (const std::invalid_argument& error) {
        PyErr_SetString(PyExc_ValueError, error.what());
    } catch (const std::bad_alloc&) {
        PyErr_NoMemory();
    }
    return nullptr;
}
PyMethodDef methods[]={{"create",create,METH_VARARGS,nullptr},{"metadata",metadata,METH_O,nullptr},{"decode",decode,METH_VARARGS,nullptr},{nullptr,nullptr,0,nullptr}};
PyModuleDef module={PyModuleDef_HEAD_INIT,"_hid_native",nullptr,-1,methods};
}
PyMODINIT_FUNC PyInit__hid_native() { return PyModule_Create(&module); }
