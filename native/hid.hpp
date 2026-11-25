#pragma once
#include <algorithm>
#include <cstdint>
#include <map>
#include <set>
#include <stdexcept>
#include <vector>

namespace rawbt::hid {
struct Field { uint32_t offset, size, page, usage; bool sign, relative, variable; };
struct Report { uint32_t bits = 0; std::vector<Field> fields; };
struct KeyboardState { std::set<uint32_t> keys, consumers; };
struct Parser {
    std::map<uint32_t, Report> reports;
    std::map<uint32_t, KeyboardState> held;
};
struct State { uint32_t page=0, size=0, count=0, report=0; int64_t minimum=0; };
constexpr const char* capsule_name = "raw_bluetooth.hid";
inline Parser parse(const uint8_t* data, size_t length) {
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
inline uint32_t extract(const uint8_t* data, const Field& field) {
    // At most five bytes, even for an unaligned 32-bit field.
    uint64_t word=0;
    unsigned shift=field.offset%8, bytes=(shift+field.size+7)/8;
    for(unsigned i=0;i<bytes;++i) word |= uint64_t(data[field.offset/8+i])<<(8*i);
    return uint32_t((word>>shift)&((uint64_t(1)<<field.size)-1));
}
struct Decoded {
    int64_t axes[4]{};
    uint8_t axis_mask = 0, button_mask = 0, buttons = 0;
    KeyboardState keyboard;
    bool rollover = false;
};

inline Decoded decode(const Parser& parser, uint32_t id, const uint8_t* data, size_t length, bool keyboard) {
    const auto it = parser.reports.find(id);
    if (it == parser.reports.end() || length < (it->second.bits + 7) / 8)
        throw std::invalid_argument("Unknown or truncated HID input report");
    Decoded result;
    for (const auto& field : it->second.fields) {
        if (!field.size || (!keyboard && !field.variable)) continue;
        const auto raw = extract(data, field);
        if (keyboard) {
            if (field.variable && !raw) continue;
            const auto usage = field.variable ? field.usage : raw;
            if (field.page == 7 && usage >= 1 && usage <= 3) {
                result.rollover = true;
                return result;
            }
            if (field.page == 7 && usage >= 4 && usage <= 0xe7) result.keyboard.keys.insert(usage);
            if (field.page == 0xc && usage) result.keyboard.consumers.insert(usage);
            continue;
        }
        if (field.page == 9 && field.usage >= 1 && field.usage <= 8) {
            const uint8_t mask = 1 << (field.usage - 1);
            result.button_mask |= mask;
            result.buttons = (result.buttons & ~mask) | (raw ? mask : 0);
            continue;
        }
        if (!field.relative) continue;
        int axis = -1;
        if (field.page == 1) {
            if (field.usage == 0x30) axis = 0;
            if (field.usage == 0x31) axis = 1;
            if (field.usage == 0x38) axis = 2;
        }
        if (field.page == 0xc && field.usage == 0x238) axis = 3;
        if (axis < 0) continue;
        result.axis_mask |= 1 << axis;
        result.axes[axis] = raw;
        if (field.sign && (raw & (uint32_t(1) << (field.size - 1))))
            result.axes[axis] -= int64_t(1) << field.size;
    }
    return result;
}
}
