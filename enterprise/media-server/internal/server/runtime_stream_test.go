package server

import (
	"encoding/binary"
	"io"
	"math"
	"net"
	"os/exec"
	"testing"
	"time"
)

func TestRuntimeFFmpegArgsEnableLowLatencyRawPcm(t *testing.T) {
	args := runtimeFFmpegArgs(49152)
	mustContainInOrder(t, args,
		"-analyzeduration", "0",
		"-probesize", "32",
		"-fflags", "nobuffer",
		"-f", "s16le",
		"-i", "pipe:0",
		"-flush_packets", "1",
		"-f", "rtp",
		"rtp://127.0.0.1:49152",
	)
}

func TestRuntimeFFmpegProducesRTPBeforeInputEOF(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg is not installed")
	}

	conn, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen udp: %v", err)
	}
	defer conn.Close()

	port := conn.LocalAddr().(*net.UDPAddr).Port
	cmd := exec.Command("ffmpeg", runtimeFFmpegArgs(port)...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatalf("start ffmpeg: %v", err)
	}
	defer func() {
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	packets := make(chan int, 1)
	go func() {
		buf := make([]byte, 2048)
		_ = conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		n, _, readErr := conn.ReadFrom(buf)
		if readErr != nil {
			packets <- 0
			return
		}
		packets <- n
	}()

	frame := runtimeToneFrame()
	deadline := time.Now().Add(1200 * time.Millisecond)
	for time.Now().Before(deadline) {
		if _, err := stdin.Write(frame); err != nil {
			t.Fatalf("write pcm frame before EOF: %v", err)
		}
		select {
		case n := <-packets:
			if n <= 0 {
				t.Fatalf("expected RTP packet before stdin EOF")
			}
			return
		case <-time.After(20 * time.Millisecond):
		}
	}

	select {
	case n := <-packets:
		if n <= 0 {
			t.Fatalf("expected RTP packet before stdin EOF")
		}
	case <-time.After(900 * time.Millisecond):
		t.Fatalf("ffmpeg did not emit RTP before stdin EOF")
	}
}

func runtimeToneFrame() []byte {
	const sampleRate = 8000
	const samplesPerFrame = 160 // 20ms at 8kHz
	frame := make([]byte, samplesPerFrame*2)
	for i := 0; i < samplesPerFrame; i++ {
		sample := int16(math.Sin(2*math.Pi*440*float64(i)/sampleRate) * 12000)
		binary.LittleEndian.PutUint16(frame[i*2:], uint16(sample))
	}
	return frame
}

func mustContainInOrder(t *testing.T, values []string, expected ...string) {
	t.Helper()
	cursor := 0
	for _, want := range expected {
		found := false
		for cursor < len(values) {
			if values[cursor] == want {
				found = true
				cursor++
				break
			}
			cursor++
		}
		if !found {
			t.Fatalf("expected %q in args after position %d: %#v", want, cursor, values)
		}
	}
}
