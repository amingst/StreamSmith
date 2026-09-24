package app

import "../audio"
import "../encode"
import "../mp4"
import "../rtmp"

Output_State :: struct {
	recording:       bool,
	streaming:       bool,
	rtmp_stream:     ^rtmp.Rtmp_Stream,
	mp4_sink:        ^mp4.Mp4_Sink,
	finalizing_sink: ^mp4.Mp4_Sink,
	enc:             ^encode.Encoder,
}

// Release encoder when the last output stops.  A finalizing sink still
// has its consumer registered (the feeder thread is still running), so
// the encoder must stay alive until the sink is reaped.
maybe_release_encoder :: proc(output: ^Output_State) {
	if output.recording || output.streaming || output.finalizing_sink != nil do return
	audio.mix_set_encoder(nil) // detach the mixer thread before the encoder goes away
	encode.encoder_release()
	output.enc = nil
}
