// SPDX-License-Identifier: MIT
package main

/*
#include <stdint.h>
*/
import "C"

import (
	"net/netip"
	"time"
	"unsafe"
)

//export clay_engine_start
func clay_engine_start(data *C.uint8_t, size C.int32_t, chosen C.int32_t, mode C.int32_t) C.uint64_t {
	if data == nil || size <= 0 || size > maxProfileBytes {
		return 0
	}
	profile := C.GoBytes(unsafe.Pointer(data), C.int(size))
	defer zeroProfile(profile)
	id, _ := start(profile, int(chosen), int(mode))
	return C.uint64_t(id)
}

//export clay_engine_start_lab
func clay_engine_start_lab(data *C.uint8_t, size C.int32_t, mode C.int32_t, destination *C.uint8_t, destinationSize C.int32_t, port C.uint16_t) C.uint64_t {
	if destination == nil || (destinationSize != 4 && destinationSize != 16) {
		return 0
	}
	ip, ok := netip.AddrFromSlice(unsafe.Slice((*byte)(unsafe.Pointer(destination)), int(destinationSize)))
	if !ok {
		return 0
	}
	profile := copyLabProfile(data, size)
	if profile == nil {
		return 0
	}
	defer zeroProfile(profile)
	id, _ := startLab(profile, int(mode), netip.AddrPortFrom(ip, uint16(port)))
	return C.uint64_t(id)
}

//export clay_engine_replace_lab
func clay_engine_replace_lab(id C.uint64_t, data *C.uint8_t, size C.int32_t, mode C.int32_t) C.int32_t {
	profile := copyLabProfile(data, size)
	if profile == nil {
		return -1
	}
	defer zeroProfile(profile)
	if !replaceLab(uint64(id), profile, int(mode)) {
		return -1
	}
	return 0
}

func copyLabProfile(data *C.uint8_t, size C.int32_t) []byte {
	if data == nil || size <= 0 || size > labProfileLimit {
		return nil
	}
	return C.GoBytes(unsafe.Pointer(data), C.int(size))
}

func zeroProfile(profile []byte) {
	for i := range profile {
		profile[i] = 0
	}
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
