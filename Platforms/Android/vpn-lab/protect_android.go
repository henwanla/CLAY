// This file is compiled only into the pinned test engine by run.sh.
package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/metacubex/mihomo/component/dialer"
	"golang.org/x/sys/unix"
)

const (
	protectFD = 101
	request   = 0x50
	accepted  = 0x01
)

func init() {
	if os.Getenv("CLAY_VPN_LAB_PROTECT") != "1" {
		return
	}
	file := os.NewFile(protectFD, "clay-protect-channel")
	conn, err := net.FileConn(file)
	_ = file.Close()
	channel, ok := conn.(*net.UnixConn)
	if err != nil || !ok {
		fmt.Fprintln(os.Stderr, "CLAY_PROBE_PROTECT_CHANNEL_INVALID")
		os.Exit(73)
	}
	var held sync.Mutex
	var broken bool
	dialer.DefaultSocketHook = func(_, _ string, socket syscall.RawConn) error {
		held.Lock()
		defer held.Unlock()
		if broken {
			return errors.New("CLAY_PROBE_PROTECT_CHANNEL_CLOSED")
		}
		var exchanged error
		if err := socket.Control(func(fd uintptr) {
			exchanged = exchangeProtection(channel, int(fd))
		}); err != nil {
			return err
		}
		if exchanged != nil && !errors.Is(exchanged, errDenied) {
			broken = true
			_ = channel.Close()
		}
		return exchanged
	}
}

var errDenied = errors.New("CLAY_PROBE_PROTECT_DENIED")

func exchangeProtection(channel *net.UnixConn, fd int) error {
	if err := channel.SetDeadline(time.Now().Add(1500 * time.Millisecond)); err != nil {
		return err
	}
	rights := unix.UnixRights(fd)
	n, oob, err := channel.WriteMsgUnix([]byte{request}, rights, nil)
	if err != nil {
		return err
	}
	if n != 1 || oob != len(rights) {
		return io.ErrShortWrite
	}
	var reply [1]byte
	if _, err := io.ReadFull(channel, reply[:]); err != nil {
		return err
	}
	switch reply[0] {
	case accepted:
		return nil
	case 0:
		return errDenied
	default:
		return errors.New("CLAY_PROBE_PROTECT_INVALID_REPLY")
	}
}
