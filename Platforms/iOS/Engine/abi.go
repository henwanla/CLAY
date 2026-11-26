// SPDX-License-Identifier: MIT
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"time"
	"unsafe"
)

//export clay_engine_start
func clay_engine_start(data *C.uint8_t, size C.int32_t, chosen C.int32_t, mode C.int32_t) C.uint64_t {
	if data == nil || size <= 0 || size > maxProfileBytes {
		return 0
	}
	profile := C.GoBytes(unsafe.Pointer(data), C.int(size))
	defer func() {
		for i := range profile {
			profile[i] = 0
		}
	}()
	id, _ := start(profile, int(chosen), int(mode))
	return C.uint64_t(id)
}

//export clay_engine_offer
func clay_engine_offer(id C.uint64_t, data *C.uint8_t, size C.int32_t) C.int32_t {
	if data == nil || size <= 0 || size > mtu {
		return -1
	}
	// Copy data into Go-owned storage; the caller can free its packet after return.
	if !offer(uint64(id), C.GoBytes(unsafe.Pointer(data), C.int(size))) {
		return -1
	}
	return 0
}

//export clay_engine_read
func clay_engine_read(id C.uint64_t, out *C.uint8_t, capacity C.int32_t, waitMS C.int32_t) C.int32_t {
	if out == nil || capacity < mtu || waitMS < 1 || waitMS > 1000 {
		return -1
	}
	bytes := unsafe.Slice((*byte)(unsafe.Pointer(out)), mtu)
	return C.int32_t(receive(uint64(id), bytes, time.Duration(waitMS)*time.Millisecond))
}

//export clay_engine_stop
func clay_engine_stop(id C.uint64_t) { stop(uint64(id)) }

func main() {}
