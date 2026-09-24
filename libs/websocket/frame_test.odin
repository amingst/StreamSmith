package websocket

import "core:slice"
import "core:testing"

// A single-frame masked text message, "Hello", from RFC 6455 section 5.7.
@(private="file")
RFC_MASKED_HELLO :: []u8{0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58}

// The same message unmasked, also from section 5.7.
@(private="file")
RFC_PLAIN_HELLO :: []u8{0x81, 0x05, 'H', 'e', 'l', 'l', 'o'}

// ---- decode ----

@(test)
decode_rfc_plain_text :: proc(t: ^testing.T) {
	src := RFC_PLAIN_HELLO
	h, n, err := decode_header(src)

	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 2)
	testing.expect_value(t, h.fin, true)
	testing.expect_value(t, h.opcode, Opcode.Text)
	testing.expect_value(t, h.masked, false)
	testing.expect_value(t, h.payload_len, 5)
	testing.expect_value(t, string(src[n:]), "Hello")
}

@(test)
decode_rfc_masked_text :: proc(t: ^testing.T) {
	src := slice.clone(RFC_MASKED_HELLO)
	defer delete(src)

	h, n, err := decode_header(src)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 6) // 2 + 4 mask key
	testing.expect_value(t, h.fin, true)
	testing.expect_value(t, h.opcode, Opcode.Text)
	testing.expect_value(t, h.masked, true)
	testing.expect_value(t, h.payload_len, 5)
	testing.expect_value(t, h.mask_key, [4]u8{0x37, 0xfa, 0x21, 0x3d})

	apply_mask(src[n:], h.mask_key)
	testing.expect_value(t, string(src[n:]), "Hello")
}

// A fragmented "Hel" + "lo", RFC 6455 section 5.7.
@(test)
decode_rfc_fragments :: proc(t: ^testing.T) {
	first := []u8{0x01, 0x03, 'H', 'e', 'l'}
	last  := []u8{0x80, 0x02, 'l', 'o'}

	h1, n1, err1 := decode_header(first)
	testing.expect_value(t, err1, Frame_Error.None)
	testing.expect_value(t, h1.fin, false)
	testing.expect_value(t, h1.opcode, Opcode.Text)
	testing.expect_value(t, string(first[n1:]), "Hel")

	h2, n2, err2 := decode_header(last)
	testing.expect_value(t, err2, Frame_Error.None)
	testing.expect_value(t, h2.fin, true)
	testing.expect_value(t, h2.opcode, Opcode.Continuation)
	testing.expect_value(t, string(last[n2:]), "lo")
}

@(test)
decode_extended_lengths :: proc(t: ^testing.T) {
	// 256 bytes: the 16-bit form.
	medium := []u8{0x82, 126, 0x01, 0x00}
	h, n, err := decode_header(medium)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, 4)
	testing.expect_value(t, h.opcode, Opcode.Binary)
	testing.expect_value(t, h.payload_len, 256)

	// 65536 bytes: the 64-bit form.
	large := []u8{0x82, 127, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00}
	h2, n2, err2 := decode_header(large)
	testing.expect_value(t, err2, Frame_Error.None)
	testing.expect_value(t, n2, 10)
	testing.expect_value(t, h2.payload_len, 65536)
}

@(test)
decode_rejects :: proc(t: ^testing.T) {
	Case :: struct { name: string, src: []u8, want: Frame_Error }
	cases := []Case{
		{"rsv1 set",             {0xC1, 0x00},                                     .Reserved_Bits},
		{"rsv2 set",             {0xA1, 0x00},                                     .Reserved_Bits},
		{"rsv3 set",             {0x91, 0x00},                                     .Reserved_Bits},
		{"reserved opcode 3",    {0x83, 0x00},                                     .Bad_Opcode},
		{"reserved opcode 0xB",  {0x8B, 0x00},                                     .Bad_Opcode},
		{"reserved opcode 0xF",  {0x8F, 0x00},                                     .Bad_Opcode},
		{"fragmented close",     {0x08, 0x00},                                     .Fragmented_Control},
		{"fragmented ping",      {0x09, 0x02, 0, 0},                               .Fragmented_Control},
		{"ping over 125",        {0x89, 126, 0x00, 0x7E},                          .Control_Too_Long},
		{"16-bit for 125",       {0x81, 126, 0x00, 0x7D},                          .Length_Not_Minimal},
		{"16-bit for 0",         {0x81, 126, 0x00, 0x00},                          .Length_Not_Minimal},
		{"64-bit for 65535",     {0x81, 127, 0, 0, 0, 0, 0, 0, 0xFF, 0xFF},        .Length_Not_Minimal},
		{"64-bit top bit set",   {0x81, 127, 0x80, 0, 0, 0, 0, 0, 0, 0},           .Length_Too_Large},
	}

	for c in cases {
		_, n, err := decode_header(c.src)
		testing.expectf(t, err == c.want, "%s: want %v, got %v", c.name, c.want, err)
		testing.expectf(t, n == 0, "%s: header_len should stay 0 on error, got %v", c.name, n)
	}
}

// Every prefix of a full header is Need_More, never a half-parsed header.
@(test)
decode_needs_more_at_every_truncation :: proc(t: ^testing.T) {
	// Masked binary frame with a 64-bit length: the longest header there is.
	full := []u8{0x82, 0xFF, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0xAA, 0xBB, 0xCC, 0xDD}
	testing.expect_value(t, len(full), MAX_HEADER)

	for cut in 0 ..< len(full) {
		_, n, err := decode_header(full[:cut])
		testing.expectf(t, err == .Need_More, "cut %v: want Need_More, got %v", cut, err)
		testing.expectf(t, n == 0, "cut %v: header_len should stay 0, got %v", cut, n)
	}

	h, n, err := decode_header(full)
	testing.expect_value(t, err, Frame_Error.None)
	testing.expect_value(t, n, MAX_HEADER)
	testing.expect_value(t, h.payload_len, 65536)
	testing.expect_value(t, h.mask_key, [4]u8{0xAA, 0xBB, 0xCC, 0xDD})
}

// ---- encode ----

@(test)
encode_matches_rfc_bytes :: proc(t: ^testing.T) {
	plain, masked := RFC_PLAIN_HELLO, RFC_MASKED_HELLO

	dst: [MAX_HEADER]u8
	n := encode_header({fin = true, opcode = .Text, payload_len = 5}, &dst)
	testing.expect_value(t, n, 2)
	testing.expect(t, slice.equal(dst[:n], plain[:2]))

	n = encode_header({
		fin = true, opcode = .Text, payload_len = 5,
		masked = true, mask_key = {0x37, 0xfa, 0x21, 0x3d},
	}, &dst)
	testing.expect_value(t, n, 6)
	testing.expect(t, slice.equal(dst[:n], masked[:6]))
}

// The encoder must pick the shortest length form, or the decoder (which
// rejects non-minimal lengths) would refuse our own frames.
@(test)
encode_picks_minimal_length_form :: proc(t: ^testing.T) {
	Case :: struct { payload_len: u64, want_len7: u8, want_header: int }
	cases := []Case{
		{0,          0,   2},
		{125,        125, 2},
		{126,        126, 4},
		{0xFFFF,     126, 4},
		{0x1_0000,   127, 10},
	}

	dst: [MAX_HEADER]u8
	for c in cases {
		n := encode_header({fin = true, opcode = .Binary, payload_len = c.payload_len}, &dst)
		testing.expectf(t, n == c.want_header, "len %v: want %v header bytes, got %v",
			c.payload_len, c.want_header, n)
		testing.expectf(t, dst[1] & 0x7F == c.want_len7, "len %v: want len7 %v, got %v",
			c.payload_len, c.want_len7, dst[1] & 0x7F)
	}
}

@(test)
encode_decode_round_trip :: proc(t: ^testing.T) {
	lengths := []u64{0, 5, 125, 126, 1024, 0xFFFF, 0x1_0000, 0x10_0000}
	opcodes := []Opcode{.Continuation, .Text, .Binary}

	dst: [MAX_HEADER]u8
	for op in opcodes {
		for payload_len in lengths {
			for masked in ([]bool{false, true}) {
				for fin in ([]bool{false, true}) {
					want := Frame_Header{
						fin         = fin,
						opcode      = op,
						masked      = masked,
						payload_len = payload_len,
					}
					if masked do want.mask_key = {0x01, 0x02, 0x03, 0x04}

					n := encode_header(want, &dst)
					got, header_len, err := decode_header(dst[:n])

					testing.expectf(t, err == .None, "%v/%v/%v: %v", op, payload_len, masked, err)
					testing.expectf(t, header_len == n, "%v/%v/%v: encoded %v bytes, decoded %v",
						op, payload_len, masked, n, header_len)
					testing.expectf(t, got == want, "%v/%v/%v: want %v, got %v",
						op, payload_len, masked, want, got)
				}
			}
		}
	}
}

@(test)
encode_control_frames_round_trip :: proc(t: ^testing.T) {
	dst: [MAX_HEADER]u8
	for op in ([]Opcode{.Close, .Ping, .Pong}) {
		want := Frame_Header{fin = true, opcode = op, payload_len = MAX_CONTROL_PAYLOAD}
		n := encode_header(want, &dst)
		got, _, err := decode_header(dst[:n])
		testing.expectf(t, err == .None, "%v: %v", op, err)
		testing.expectf(t, got == want, "%v: want %v, got %v", op, want, got)
	}
}

// ---- masking ----

@(test)
mask_is_its_own_inverse :: proc(t: ^testing.T) {
	key := [4]u8{0x37, 0xfa, 0x21, 0x3d}
	original := "the quick brown fox jumps over the lazy dog"

	buf := make([]u8, len(original))
	defer delete(buf)
	copy(buf, original)

	apply_mask(buf, key)
	testing.expect(t, string(buf) != original, "masking should change the payload")

	apply_mask(buf, key)
	testing.expect_value(t, string(buf), original)
}

// A payload that arrives across several reads is unmasked chunk by chunk,
// with offset keeping the key aligned. It must match a single pass.
@(test)
mask_in_chunks_matches_single_pass :: proc(t: ^testing.T) {
	key := [4]u8{0xAA, 0x0F, 0x55, 0xF0}

	payload := make([]u8, 37)
	defer delete(payload)
	for &b, i in payload do b = u8(i * 7)

	one_pass := slice.clone(payload)
	defer delete(one_pass)
	apply_mask(one_pass, key)

	// Chunk sizes that don't line up with the 4-byte key.
	chunked := slice.clone(payload)
	defer delete(chunked)
	offset := 0
	for size in ([]int{1, 2, 3, 5, 7, 11, 8}) {
		end := min(offset + size, len(chunked))
		apply_mask(chunked[offset:end], key, offset)
		offset = end
	}
	testing.expect_value(t, offset, len(chunked))
	testing.expect(t, slice.equal(chunked, one_pass))
}

@(test)
mask_handles_empty_payload :: proc(t: ^testing.T) {
	apply_mask(nil, {1, 2, 3, 4})       // must not crash
	apply_mask([]u8{}, {1, 2, 3, 4}, 3)
}

// ---- close codes ----

@(test)
close_codes_for_errors :: proc(t: ^testing.T) {
	testing.expect_value(t, close_code_for(.Length_Too_Large), 1009)

	for err in ([]Frame_Error{
		.Reserved_Bits, .Bad_Opcode, .Fragmented_Control,
		.Control_Too_Long, .Length_Not_Minimal,
	}) {
		testing.expectf(t, close_code_for(err) == 1002, "%v: want 1002, got %v", err, close_code_for(err))
	}
}
