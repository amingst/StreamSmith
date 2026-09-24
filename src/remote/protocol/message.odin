package protocol

import "core:encoding/json"

Error_Body :: struct {
	code:    string,
	message: string `json:"message,omitempty"`,
}

Welcome :: struct {
	type:     string,
	protocol: int,
	server:   string,
}

Response :: struct {
	type:   string,
	id:     i64,
	ok:     bool,
	result: json.Value       `json:"result,omitempty"`,
	error:  Maybe(Error_Body) `json:"error,omitempty"`,
}

Event :: struct {
	type:  string,
	event: string,
	data:  json.Value,
}

Error_Message :: struct {
	type:      string,
	code:      string,
	message:   string `json:"message,omitempty"`,
	supported: []int  `json:"supported,omitempty"`,
}

Hello :: struct {
	protocol: int,
	client:   string,
}

Params_Scene_Set :: struct {
	scene_id: string,
}

Params_Subscribe :: struct {
	topics: Topic_Set,
}

Params_Mute :: struct {
	source_id: string,
	muted:     Maybe(bool),
}

Params_Volume :: struct {
	source_id: string,
	volume:    f32,
}

Params_Visible :: struct {
	scene_id:  string,
	source_id: string,
	visible:   Maybe(bool),
}

Params :: union {
	Params_Scene_Set,
	Params_Subscribe,
	Params_Mute,
	Params_Volume,
	Params_Visible,
}

Request :: struct {
	id:     i64,
	method: Method,
	params: Params,
}

Inbound :: union {
	Hello,
	Request,
}

Fault :: struct {
	code:    Error_Code,
	message: string,
	id:      Maybe(i64),
}
