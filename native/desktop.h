#pragma once

#include <CoreGraphics/CoreGraphics.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint64_t device;
    uint64_t timestamp;
    int16_t x, y, wheel, pan;
    uint8_t kind, has_buttons, buttons, keys, consumers;
} RawBTInput;

// Keyboard usages follow the 14-byte wire header as little-endian uint16s.
int rawbt_parse_input(const uint8_t *bytes, size_t length, RawBTInput *report);

CGPoint rawbt_clamp(CGPoint point, const CGRect *displays, size_t count);
void *rawbt_pointer_create(double sensitivity, double scroll, double page);
void rawbt_pointer_destroy(void *context);
void rawbt_pointer_set_sensitivity(void *context, double value);
void rawbt_pointer_set_scroll(void *context, double value);
void rawbt_pointer_set_page(void *context, double value);
void rawbt_pointer_apply(void *context, const RawBTInput *report, int release_all,
                         CGEventFlags flags, double double_click_interval);

typedef void (*RawBTKeyTransition)(void *owner, int usage, int down, int media);
void *rawbt_keyboard_create(void);
void rawbt_keyboard_destroy(void *context);
// mode 0 replaces device state, 1 releases a device, and 2 releases all.
void rawbt_keyboard_update(void *context, uint64_t device, int mode,
                           const uint16_t *keys, size_t key_count,
                           const uint16_t *media, size_t media_count,
                           void *owner, RawBTKeyTransition transition);
void rawbt_post_key(uint16_t code, int down, int modifier, int repeat, CGEventFlags flags);

void *rawbt_pcm_create(void);
void rawbt_pcm_destroy(void *context);
// The returned stereo float buffer is valid until the next conversion.
const float *rawbt_pcm_convert(void *context, const void *left, const void *right,
                               size_t frames, int bits, int floating, double rate,
                               size_t *sample_count);

#ifdef __cplusplus
}
#endif
