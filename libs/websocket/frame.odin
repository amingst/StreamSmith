package websocket

import "core:encoding/endian"

MAX_HEADER :: 14
MAX_CONTROL_PAYLOAD :: 125

Opcode :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

is_control :: proc(op: Opcode) -> bool {
	return op == .Close || op == .Ping || op == .Pong
}

Frame_Header :: struct {
	fin:         bool,
	opcode:      Opcode,
	masked:      bool,
	mask_key:    [4]u8, // only meaningful when masked
	payload_len: u64,   // bytes of payload following the header
}

Frame_Error :: enum {
	None,
	Need_More,          // src doesn't hold a whole header yet -- read more, not an error
	Reserved_Bits,      // RSV1..3 set, but no extension was negotiated
	Bad_Opcode,         // reserved opcode
	Fragmented_Control, // control frame with FIN clear
	Control_Too_Long,   // control frame payload over 125 bytes
	Length_Not_Minimal, // 126/127 used for a length that fits a shorter form
	Length_Too_Large,   // 64-bit length with the top bit set, or over max(int)
}


encode_header :: proc(h: Frame_Header, dst: ^[MAX_HEADER]u8) -> int {
	dst[0] = (h.fin ? 0x80 : 0) | u8(h.opcode)
	len7: u8

	if h.payload_len <= 125 {
		len7 = u8(h.payload_len)
	}
	else if h.payload_len <= 0xFFFF {
		len7 = 126
	}
	else {
		len7 = 127
	}

	dst[1] = (h.masked ? 0x80 : 0) | len7

	n := 2

	if len7 == 126 {
		_ = endian.put_u16(dst[2:4], .Big, u16(h.payload_len))
		n += 2
	}
	else if len7 == 127 {
		_ = endian.put_u64(dst[2:10], .Big, h.payload_len)
		n += 8
	}

	if h.masked {
		key := h.mask_key
		copy(dst[n:n+4], key[:])
		n += 4
	}

	return n
}

decode_header :: proc(src: []u8) -> (h: Frame_Header, header_len: int, err: Frame_Error) {
	if len(src) < 2 do return {}, 0, .Need_More

	// byte 0
	if src[0] & 0x70 != 0 do return {}, 0, .Reserved_Bits
	op := Opcode(src[0] & 0x0F)
	if !is_valid_opcode(op) do return {}, 0, .Bad_Opcode
	h.opcode = op

	// byte 1
	h.masked = src[1] & 0x80 != 0
	h.payload_len = u64(src[1] & 0x7F)
	h.fin = src[0] & 0x80 != 0

	if is_control(op) {
	    if !h.fin              					do return {}, 0, .Fragmented_Control
	    if h.payload_len > MAX_CONTROL_PAYLOAD 	do return {}, 0, .Control_Too_Long
	}

	need := 2

	switch h.payload_len {
	case 126:
		need += 2
		if len(src) < need do return {}, 0, .Need_More
		n, _ := endian.get_u16(src[2:4], .Big)
		if n < 126 do return {}, 0, .Length_Not_Minimal
		h.payload_len = u64(n)

	case 127:
		need += 8
		if len(src) < need do return {}, 0, .Need_More
		n, _ := endian.get_u64(src[2:10], .Big)
		if n & 0x8000_0000_0000_0000 != 0 do return {}, 0, .Length_Too_Large
		if n <= 0xFFFF                    do return {}, 0, .Length_Not_Minimal
		if n > u64(max(int))              do return {}, 0, .Length_Too_Large
		h.payload_len = n
	}

	if h.masked {
		need += 4
		if len(src) < need do return {}, 0, .Need_More
		copy(h.mask_key[:], src[need - 4:need])
	}

	return h, need, .None
}

apply_mask :: proc(payload: []u8, key: [4]u8, offset := 0) {
	for i in 0..<len(payload) {
		// ~= is XOR-assign  because odin can be dumb sometimes
		payload[i] ~= key[(i + offset) % 4]
	}
}

close_code_for :: proc(err: Frame_Error) -> u16 {
	#partial switch err {
	case .Length_Too_Large: return 1009
	case : return 1002
	}
}

@(private)
is_valid_opcode :: proc(op: Opcode) -> bool {
	switch op {
	case .Continuation, .Text, .Binary, .Close, .Ping, .Pong: return true
	case: return false
	}
}
