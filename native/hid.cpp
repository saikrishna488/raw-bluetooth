#define PY_SSIZE_T_CLEAN
#include <Python.h>
#include <cstdint>
#include <map>
#include <vector>
#include <stdexcept>
#include <algorithm>

namespace {
struct Field { uint32_t offset, size, page, usage; bool sign, relative, variable; };
struct Report { uint32_t bits = 0; std::vector<Field> fields; };
struct Parser { std::map<uint32_t, Report> reports; };
struct State { uint32_t page=0, size=0, count=0, report=0; int64_t minimum=0; };
constexpr const char* capsule_name = "raw_bluetooth.hid";
void destroy(PyObject* obj) { delete static_cast<Parser*>(PyCapsule_GetPointer(obj, capsule_name)); }
Parser* get(PyObject* obj) { return static_cast<Parser*>(PyCapsule_GetPointer(obj, capsule_name)); }
Parser parse(const uint8_t* data, size_t length) {
    Parser parser;
    State state;
    std::vector<State> stack;
    std::vector<uint32_t> usages;
    int64_t low=-1, high=-1;
    size_t pos=0, total_fields=0;
    while (pos < length) {
        uint8_t prefix=data[pos++];
        if (prefix == 0xfe) {
            if (length-pos < 2) throw std::runtime_error("Truncated long HID item");
            size_t count=data[pos]; pos+=2;
            if (length-pos < count) throw std::runtime_error("Truncated long HID payload");
            pos+=count; continue;
        }
        const unsigned sizes[]={0,1,2,4};
        unsigned size=sizes[prefix&3], kind=(prefix>>2)&3, tag=prefix>>4;
        if (length-pos < size) throw std::runtime_error("Truncated HID item");
        uint32_t value=0;
        for (unsigned i=0; i<size; ++i) value |= uint32_t(data[pos++]) << (i*8);
        if (kind==1) {
            switch(tag) {
                case 0: state.page=value; break;
                case 1: state.minimum=value; if(size && (value & (uint32_t(1)<<(size*8-1)))) state.minimum-=int64_t(1)<<(size*8); break;
                case 7: state.size=value; break;
                case 8: state.report=value; break;
                case 9: state.count=value; break;
                case 10: stack.push_back(state); break;
                case 11: if(stack.empty()) throw std::runtime_error("Unbalanced HID global pop"); state=stack.back(); stack.pop_back(); break;
            }
        } else if (kind==2) {
            if(tag==0) usages.push_back(value);
            else if(tag==1) low=value;
            else if(tag==2) high=value;
        } else if(kind==0) {
            if(tag==8) {
                if(state.size>32 || state.count>1024) throw std::runtime_error("Unsupported HID field dimensions");
                auto choices=usages;
                if(low>=0 && high>=0) {
                    if(high-low>1024) throw std::runtime_error("Excessive HID usage range");
                    for(int64_t u=low; u<=high; ++u) choices.push_back(uint32_t(u));
                }
                auto& report=parser.reports[state.report];
                if(uint64_t(report.bits)+uint64_t(state.size)*state.count > 8*1024*1024)
                    throw std::runtime_error("Excessive HID report length");
                for(uint32_t i=0; i<state.count; ++i) {
                    if(!(value&1) && !choices.empty()) {
                        if(++total_fields>65536) throw std::runtime_error("Excessive HID field count");
                        uint32_t usage=choices[(value&2)?std::min(size_t(i),choices.size()-1):0];
                        report.fields.push_back({report.bits,state.size,usage>0xffff?usage>>16:state.page,usage&0xffff,state.minimum<0,bool(value&4),bool(value&2)});
                    }
                    report.bits+=state.size;
                }
            }
            usages.clear(); low=high=-1;
        }
    }
    return parser;
}
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
uint32_t extract(const uint8_t* data, const Field& field) {
    // At most five bytes, even for an unaligned 32-bit field.
    uint64_t word=0;
    unsigned shift=field.offset%8, bytes=(shift+field.size+7)/8;
    for(unsigned i=0;i<bytes;++i) word |= uint64_t(data[field.offset/8+i])<<(8*i);
    return uint32_t((word>>shift)&((uint64_t(1)<<field.size)-1));
}
PyObject* decode(PyObject*, PyObject* args) {
    PyObject* capsule; unsigned id; const char* bytes; Py_ssize_t length; int keyboard;
    if(!PyArg_ParseTuple(args,"OIy#p",&capsule,&id,&bytes,&length,&keyboard)) return nullptr;
    auto* p=get(capsule); if(!p) return nullptr;
    auto it=p->reports.find(id);
    if(it==p->reports.end() || size_t(length)<(it->second.bits+7)/8) { PyErr_SetString(PyExc_ValueError,"Unknown or truncated HID input report"); return nullptr; }
    PyObject* result=keyboard?PySet_New(nullptr):PyDict_New();
    PyObject* consumer=keyboard?PySet_New(nullptr):nullptr;
    if(!result || (keyboard&&!consumer)) { Py_XDECREF(result); Py_XDECREF(consumer); return nullptr; }
    for(const auto& f:it->second.fields) {
        if(!f.size || (!keyboard&&!f.variable)) continue;
        uint32_t raw=extract(reinterpret_cast<const uint8_t*>(bytes),f);
        if(keyboard) {
            uint32_t usage=f.variable?f.usage:raw;
            if(f.variable&&!raw) continue;
            if(f.page==7 && usage>=1 && usage<=3) { Py_DECREF(result); Py_DECREF(consumer); Py_RETURN_NONE; }
            PyObject* target=f.page==7 && usage>=4 && usage<=0xe7?result:f.page==0xc && usage?consumer:nullptr;
            if(target) { PyObject* value=PyLong_FromUnsignedLong(usage); if(!value || PySet_Add(target,value)<0) { Py_XDECREF(value); Py_DECREF(result); Py_DECREF(consumer); return nullptr; } Py_DECREF(value); }
        } else {
            const char* key=nullptr; char button[]="button1";
            bool is_button=f.page==9 && f.usage>=1 && f.usage<=8;
            if(is_button) { button[6]=char('0'+f.usage); key=button; }
            else if(f.relative&&f.page==1) key=f.usage==0x30?"x":f.usage==0x31?"y":f.usage==0x38?"wheel":nullptr;
            else if(f.relative&&f.page==0xc&&f.usage==0x238) key="pan";
            if(!key) continue;
            int64_t value=raw;
            if(f.sign && (raw&(uint32_t(1)<<(f.size-1)))) value-=int64_t(1)<<f.size;
            PyObject* obj=is_button?PyBool_FromLong(raw!=0):PyLong_FromLongLong(value);
            if(!obj || PyDict_SetItemString(result,key,obj)<0) { Py_XDECREF(obj); Py_DECREF(result); return nullptr; } Py_DECREF(obj);
        }
    }
    return keyboard?Py_BuildValue("(NN)",result,consumer):result;
}
PyMethodDef methods[]={{"create",create,METH_VARARGS,nullptr},{"metadata",metadata,METH_O,nullptr},{"decode",decode,METH_VARARGS,nullptr},{nullptr,nullptr,0,nullptr}};
PyModuleDef module={PyModuleDef_HEAD_INIT,"_hid_native",nullptr,-1,methods};
}
PyMODINIT_FUNC PyInit__hid_native() { return PyModule_Create(&module); }
