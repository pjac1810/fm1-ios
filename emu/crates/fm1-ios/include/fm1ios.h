/*
 * fm1ios.h — the emulated M-VAVE FM-1 (fm1-emu's machine) for the iOS app.
 * Implemented in Rust: emu/crates/fm1-ios/src/lib.rs (documentation of each call there).
 *
 * Threads: fm1ios_pull is the audio callback's call (real-time safe). The input calls
 * (key, enc, pot, analog, midi) may come from any thread. Boot, start, stop and the panel
 * calls belong to the main thread.
 */
#ifndef FM1IOS_H
#define FM1IOS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Fm1Stats {
    float speed;        /* emulated time per time spent: >= 1 keeps up with the audio */
    uint64_t underruns; /* audio callbacks that found too little audio */
    uint32_t emu_ms;    /* emulated milliseconds since boot */
    uint32_t buffered;  /* frames ready */
    uint32_t halted;    /* 1: the firmware stopped */
    uint32_t running;   /* 1: the emulation thread runs */
} Fm1Stats;

const char *fm1ios_version(void);
uint32_t fm1ios_sample_rate(void);

/* The identity an update package carries ("FM-1_015" for M-VAVE's V15); -1: not a package. */
int32_t fm1ios_package_identity(const uint8_t *pkg, size_t len, char *out, size_t cap);

/* Boot a .fwsc package (replaces the machine). Returns 0 booted, 1 not an FM-1 package,
 * 2 booted without the saved sectors, 3 booted without the DX7 bank, 4 the firmware takes no bank. */
int32_t fm1ios_boot(const uint8_t *pkg, size_t len, const uint8_t *sectors, size_t sectors_len,
                    const uint8_t *syx, size_t syx_len, uint32_t mhz);
int32_t fm1ios_start(void);
void fm1ios_stop(void);
uint32_t fm1ios_is_running(void);
void fm1ios_set_buffer(uint32_t frames);

/* Audio: frames of non-interleaved float stereo at 44100 Hz. */
uint32_t fm1ios_pull(float *l, float *r, uint32_t frames);

/* Input. Keys: 0..13 the buttons, 14..40 the note keys. Encoders: 0 SELECT, 1 ALGORITHM,
 * 2..5 KNOB1..4, 6 PRESETS. Pot: 0..1023. */
void fm1ios_key(uint32_t id, uint32_t down);
void fm1ios_enc(uint32_t enc, int32_t clicks);
void fm1ios_pot(uint32_t value);
void fm1ios_analog(uint32_t idx, uint32_t value);
void fm1ios_midi(const uint8_t *bytes, size_t len);

/* Output. */
uint32_t fm1ios_lcd(uint16_t *dst);          /* 240*240 RGB565; returns the revision */
uint32_t fm1ios_lcd_revision(void);
void fm1ios_leds(float *dst);                /* 41 levels */
void fm1ios_stats(Fm1Stats *out);

/* Flash persistence: records (u32 LE offset + 4096 bytes) for the next fm1ios_boot. */
void fm1ios_request_save(void);
uint8_t *fm1ios_take_save(size_t *len);
void fm1ios_free(uint8_t *p, size_t len);

/* The front panel's drawing (1280 x 820 RGBA) and hit testing. Main thread. */
uint32_t fm1ios_panel_width(void);
uint32_t fm1ios_panel_height(void);
const uint8_t *fm1ios_panel_draw(const uint16_t *lcd, const float *leds);
void fm1ios_panel_set(uint32_t kind, uint32_t i, int32_t v);
int32_t fm1ios_panel_hit(float x, float y);
uint32_t fm1ios_panel_enc_id(uint32_t i);

#ifdef __cplusplus
}
#endif

#endif
