#ifndef CLAY_PACKET_ENGINE_H
#define CLAY_PACKET_ENGINE_H
#include <stdint.h>

// Stable subset of the header emitted by Engine/build.sh. Packet/profile
// inputs are borrowed for the duration of the call; only read writes its buffer.
uint64_t clay_engine_start(uint8_t *_Nonnull profile, int32_t count, int32_t chosen, int32_t mode);
uint64_t clay_engine_start_lab(uint8_t *_Nonnull profile, int32_t count, int32_t mode);
int32_t clay_engine_replace_lab(uint64_t id, uint8_t *_Nonnull profile, int32_t count, int32_t mode);
int32_t clay_engine_offer(uint64_t id, uint8_t *_Nonnull packet, int32_t count);
int32_t clay_engine_read(uint64_t id, uint8_t *_Nonnull buffer, int32_t capacity, int32_t wait_ms);
void clay_engine_stop(uint64_t id);
#endif
