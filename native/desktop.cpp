#include "desktop.h"

#include <algorithm>
#include <array>
#include <map>
#include <set>
#include <cmath>
#include <chrono>
#include <cstring>
#include <new>
#include <vector>

namespace {
uint64_t little_endian(const uint8_t* bytes, size_t length) {
    uint64_t value = 0;
    for (size_t index = 0; index < length; ++index)
        value |= uint64_t(bytes[index]) << (index * 8);
    return value;
}

template <typename T>
T sample(const void* bytes, size_t index) {
    T value;
    std::memcpy(&value, static_cast<const uint8_t*>(bytes) + index * sizeof(T), sizeof(T));
    return value;
}

template <typename T>
void convert(std::vector<float>& output, const void* left, const void* right,
             size_t frames, double rate, double scale) {
    const size_t stride = right ? 1 : 2;
    const void* second = right ? right : left;
    const size_t second_offset = right ? 0 : 1;
    for (size_t frame = 0; frame < output.size() / 2; ++frame) {
        const double position = double(frame) * rate / 48000;
        const size_t low = std::min(size_t(position), frames - 1);
        const size_t high = std::min(low + 1, frames - 1);
        const float fraction = float(position - double(low));
        const float a = float(sample<T>(left, low * stride) * scale);
        const float b = float(sample<T>(left, high * stride) * scale);
        const float c = float(sample<T>(second, low * stride + second_offset) * scale);
        const float d = float(sample<T>(second, high * stride + second_offset) * scale);
        output[frame * 2] = a + (b - a) * fraction;
        output[frame * 2 + 1] = c + (d - c) * fraction;
    }
}
}

int rawbt_parse_input(const uint8_t* bytes, size_t length, RawBTInput* report) {
    if (length < 12 || bytes[0] != 1) return 0;
    RawBTInput result{};
    result.kind = bytes[1];
    result.device = little_endian(bytes + 4, 8);
    switch (result.kind) {
    case 1:
        result.has_buttons = bytes[2] & 1;
        if (length < (result.has_buttons ? 21u : 28u)) return 0;
        result.x = int16_t(little_endian(bytes + 12, 2));
        result.y = int16_t(little_endian(bytes + 14, 2));
        result.wheel = int16_t(little_endian(bytes + 16, 2));
        result.pan = int16_t(little_endian(bytes + 18, 2));
        if (result.has_buttons) result.buttons = bytes[20];
        else result.timestamp = little_endian(bytes + 20, 8);
        break;
    case 2:
        if (length < 14 || length != 14u + 2u * (bytes[12] + bytes[13])) return 0;
        result.keys = bytes[12];
        result.consumers = bytes[13];
        break;
    case 3:
        break;
    default:
        return 0;
    }
    *report = result;
    return 1;
}

void* rawbt_pcm_create() {
    return new (std::nothrow) std::vector<float>;
}

void rawbt_pcm_destroy(void* context) {
    delete static_cast<std::vector<float>*>(context);
}

const float* rawbt_pcm_convert(void* context, const void* left, const void* right,
                               size_t frames, int bits, int floating, double rate,
                               size_t* sample_count) {
    *sample_count = 0;
    if (!context || !left || frames == 0 || frames > UINT32_MAX ||
        !(rate >= 8000 && rate <= 96000) || (bits != 16 && bits != 32)) return nullptr;
    auto& output = *static_cast<std::vector<float>*>(context);
    try {
        output.resize(2 * std::max(size_t(1), size_t(double(frames) * 48000 / rate)));
        if (bits == 16) convert<int16_t>(output, left, right, frames, rate, 1.0 / 32768);
        else if (floating) convert<float>(output, left, right, frames, rate, 1);
        else convert<int32_t>(output, left, right, frames, rate, 1.0 / 2147483648);
    } catch (...) {
        return nullptr;
    }
    *sample_count = output.size();
    return output.data();
}

namespace {
struct PointerState {
    double sensitivity, scroll, page;
    double remainder_x = 0, remainder_y = 0, remainder_wheel = 0, remainder_pan = 0;
    uint8_t buttons = 0;
    struct Click {
        double time = 0;
        CGPoint position{};
        int64_t count = 1;
    };
    std::array<Click, 8> clicks;
    std::map<uint64_t, uint8_t> devices;
    std::vector<CGRect> displays;
    double display_time = 0;

    PointerState(double speed, double scroll_speed, double page_length)
        : sensitivity(speed), scroll(scroll_speed), page(page_length) {}

    void refresh_displays(double now) {
        if (!displays.empty() && now - display_time < 1) return;
        uint32_t count = 0;
        if (CGGetActiveDisplayList(0, nullptr, &count) != kCGErrorSuccess) return;
        std::vector<CGDirectDisplayID> ids(count);
        if (CGGetActiveDisplayList(count, ids.data(), &count) != kCGErrorSuccess) return;
        displays.clear();
        for (size_t i = 0; i < count; ++i) displays.push_back(CGDisplayBounds(ids[i]));
        display_time = now;
    }
};

int64_t scaled(double amount, double scale, double& remainder) {
    const double raw = amount * scale + remainder;
    const auto rounded = std::llround(raw);
    remainder = raw - double(rounded);
    return rounded;
}

void post(CGEventRef event) {
    if (!event) return;
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
}
}

CGPoint rawbt_clamp(CGPoint point, const CGRect* displays, size_t count) {
    CGPoint closest = point;
    double distance = INFINITY;
    for (size_t index = 0; index < count; ++index) {
        const auto bounds = displays[index];
        if (bounds.size.width < 1 || bounds.size.height < 1) continue;
        const CGPoint candidate{
            std::clamp(point.x, CGRectGetMinX(bounds), CGRectGetMaxX(bounds) - 1),
            std::clamp(point.y, CGRectGetMinY(bounds), CGRectGetMaxY(bounds) - 1)
        };
        const double x = candidate.x - point.x, y = candidate.y - point.y;
        const double squared = x * x + y * y;
        if (squared < distance) { closest = candidate; distance = squared; }
    }
    return closest;
}

void* rawbt_pointer_create(double sensitivity, double scroll, double page) {
    return new (std::nothrow) PointerState(sensitivity, scroll, page);
}

void rawbt_pointer_destroy(void* context) {
    delete static_cast<PointerState*>(context);
}

void rawbt_pointer_set_sensitivity(void* context, double value) {
    auto& state = *static_cast<PointerState*>(context);
    state.sensitivity = value;
    state.remainder_x = state.remainder_y = 0;
}

void rawbt_pointer_set_scroll(void* context, double value) {
    auto& state = *static_cast<PointerState*>(context);
    state.scroll = value;
    state.remainder_wheel = state.remainder_pan = 0;
}

void rawbt_pointer_set_page(void* context, double value) {
    auto& state = *static_cast<PointerState*>(context);
    state.page = value;
    state.remainder_wheel = 0;
}

void rawbt_pointer_apply(void* context, const RawBTInput* report, int release_all,
                         CGEventFlags flags, double double_click_interval) {
    auto& state = *static_cast<PointerState*>(context);
    const bool update = release_all || report->kind == 3 || report->has_buttons;
    uint8_t combined = 0;
    try {
        if (release_all) state.devices.clear();
        else if (report->kind == 3) state.devices.erase(report->device);
        else if (report->has_buttons) state.devices[report->device] = report->buttons;
        if (update) for (const auto& device : state.devices) combined |= device.second;
        const auto uptime = std::chrono::steady_clock::now().time_since_epoch();
        state.refresh_displays(std::chrono::duration<double>(uptime).count());
    } catch (const std::bad_alloc&) {
        return;
    }

    auto current = CGEventCreate(nullptr);
    if (!current) return;
    const auto location = CGEventGetLocation(current);
    CFRelease(current);
    const auto origin = rawbt_clamp(location, state.displays.data(), state.displays.size());
    const auto dx = scaled(report->x, state.sensitivity, state.remainder_x);
    const auto dy = scaled(report->y, state.sensitivity, state.remainder_y);
    const CGPoint proposed{origin.x + double(dx), origin.y + double(dy)};
    const auto point = rawbt_clamp(proposed, state.displays.data(), state.displays.size());
    if (point.x != proposed.x) state.remainder_x = 0;
    if (point.y != proposed.y) state.remainder_y = 0;

    if (dx || dy) {
        const unsigned button = state.buttons ? unsigned(__builtin_ctz(unsigned(state.buttons))) : 0;
        const CGEventType type = !state.buttons ? kCGEventMouseMoved : button == 0 ?
            kCGEventLeftMouseDragged : button == 1 ? kCGEventRightMouseDragged : kCGEventOtherMouseDragged;
        if (auto event = CGEventCreateMouseEvent(nullptr, type, point, static_cast<CGMouseButton>(button))) {
            CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, std::llround(point.x - origin.x));
            CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, std::llround(point.y - origin.y));
            CGEventSetFlags(event, CGEventGetFlags(event) | flags);
            post(event);
        }
    }
    if (update) {
        constexpr CGEventType press[]{kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown};
        constexpr CGEventType release[]{kCGEventLeftMouseUp, kCGEventRightMouseUp, kCGEventOtherMouseUp};
        const uint8_t changed = combined ^ state.buttons;
        for (unsigned button = 0; button < state.clicks.size(); ++button) {
            const unsigned mask = 1 << button;
            if (!(changed & mask)) continue;
            const bool down = combined & mask;
            auto& click = state.clicks[button];
            if (down) {
                const auto now = CFAbsoluteTimeGetCurrent();
                const auto distance = std::hypot(point.x - click.position.x, point.y - click.position.y);
                click.count = now - click.time <= double_click_interval && distance < 5 ? click.count + 1 : 1;
                click.time = now;
                click.position = point;
            }
            const auto type = (down ? press : release)[std::min(button, 2u)];
            if (auto event = CGEventCreateMouseEvent(nullptr, type, point, static_cast<CGMouseButton>(button))) {
                CGEventSetIntegerValueField(event, kCGMouseEventClickState, click.count);
                CGEventSetFlags(event, CGEventGetFlags(event) | flags);
                post(event);
            }
        }
        state.buttons = combined;
    }
    const auto wheel = scaled(report->wheel * state.scroll, state.page, state.remainder_wheel);
    const auto pan = scaled(report->pan, state.scroll, state.remainder_pan);
    if (wheel || pan)
        post(CGEventCreateScrollWheelEvent2(nullptr, kCGScrollEventUnitLine, 2, int32_t(wheel), int32_t(pan), 0));
}

namespace {
using Usages = std::set<uint16_t>;
struct HeldUsages { Usages keys, media; };
struct KeyboardState {
    std::map<uint64_t, HeldUsages> devices;
    HeldUsages current;
};
}

void* rawbt_keyboard_create() {
    return new (std::nothrow) KeyboardState;
}

void rawbt_keyboard_destroy(void* context) {
    delete static_cast<KeyboardState*>(context);
}

void rawbt_keyboard_update(void* context, uint64_t device, int mode,
                           const uint16_t* keys, size_t key_count,
                           const uint16_t* media, size_t media_count,
                           void* owner, RawBTKeyTransition transition) {
    if (!context) return;
    auto& state = *static_cast<KeyboardState*>(context);
    HeldUsages next;
    try {
        if (mode == 2) state.devices.clear();
        else if (mode == 1) state.devices.erase(device);
        else {
            HeldUsages input;
            if (key_count) input.keys.insert(keys, keys + key_count);
            if (media_count) input.media.insert(media, media + media_count);
            state.devices[device] = std::move(input);
        }
        for (const auto& [id, usages] : state.devices) {
            next.keys.insert(usages.keys.begin(), usages.keys.end());
            next.media.insert(usages.media.begin(), usages.media.end());
        }
    } catch (const std::bad_alloc&) {
        return;
    }
    // Release ordinary keys before modifiers and press modifiers before keys.
    for (bool modifier : {false, true})
        for (auto usage : state.current.keys)
            if ((usage >= 224) == modifier && !next.keys.count(usage))
                transition(owner, usage, 0, 0);
    for (bool modifier : {true, false})
        for (auto usage : next.keys)
            if ((usage >= 224) == modifier && !state.current.keys.count(usage))
                transition(owner, usage, 1, 0);
    for (auto usage : state.current.media)
        if (!next.media.count(usage)) transition(owner, usage, 0, 1);
    for (auto usage : next.media)
        if (!state.current.media.count(usage)) transition(owner, usage, 1, 1);
    state.current = std::move(next);
}

void rawbt_post_key(uint16_t code, int down, int modifier, int repeat, CGEventFlags flags) {
    if (auto event = CGEventCreateKeyboardEvent(nullptr, code, down)) {
        if (modifier) CGEventSetType(event, kCGEventFlagsChanged);
        CGEventSetFlags(event, flags);
        if (repeat) CGEventSetIntegerValueField(event, kCGKeyboardEventAutorepeat, 1);
        post(event);
    }
}
