package protocol

import "core:strings"
import "core:testing"

@(private="file")
decode :: proc(s: string) -> (Inbound, Maybe(Fault)) {
	return decode_inbound(transmute([]u8)s, context.temp_allocator)
}

@(private="file")
expect_fault :: proc(t: ^testing.T, s: string, want: Error_Code, want_id: Maybe(i64) = nil) {
	msg, fault := decode(s)
	got, is_fault := fault.(Fault)
	if !testing.expectf(t, is_fault, "%s: wanted a fault, got %v", s, msg) do return
	testing.expectf(t, got.code == want, "%s: want %v, got %v (%s)", s, want, got.code, got.message)
	testing.expectf(t, got.id == want_id, "%s: want id %v, got %v", s, want_id, got.id)
}

@(test)
hello_is_decoded :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"hello","protocol":1,"client":"websocat"}`)
	testing.expect_value(t, fault, nil)

	hello, ok := msg.(Hello)
	if !testing.expect(t, ok, "wanted a Hello") do return
	testing.expect_value(t, hello.protocol, 1)
	testing.expect_value(t, hello.client, "websocat")
}

@(test)
hello_client_is_optional :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"hello","protocol":2}`)
	testing.expect_value(t, fault, nil)

	hello, ok := msg.(Hello)
	if !testing.expect(t, ok, "wanted a Hello") do return
	testing.expect_value(t, hello.protocol, 2)
	testing.expect_value(t, hello.client, "")
}

@(test)
every_method_name_decodes :: proc(t: ^testing.T) {
	params := [Method]string{
		.State_Get             = "",
		.Events_Subscribe      = `,"params":{"events":["scene"]}`,
		.Scene_Set             = `,"params":{"sceneId":"S"}`,
		.Recording_Start       = "",
		.Recording_Stop        = "",
		.Recording_Toggle      = "",
		.Streaming_Start       = "",
		.Streaming_Stop        = "",
		.Streaming_Toggle      = "",
		.Audio_Set_Mute        = `,"params":{"sourceId":"A","muted":true}`,
		.Audio_Toggle_Mute     = `,"params":{"sourceId":"A"}`,
		.Audio_Set_Volume      = `,"params":{"sourceId":"A","volume":0.5}`,
		.Source_Set_Visible    = `,"params":{"sceneId":"S","sourceId":"A","visible":false}`,
		.Source_Toggle_Visible = `,"params":{"sceneId":"S","sourceId":"A"}`,
	}

	for name, method in method_names {
		raw := strings.concatenate({
			`{"type":"request","id":1,"method":"`, name, `"`, params[method], `}`,
		}, context.temp_allocator)
		msg, fault := decode(raw)
		testing.expectf(t, fault == nil, "%s: %v", name, fault)

		req, ok := msg.(Request)
		testing.expectf(t, ok, "%s: wanted a Request", name)
		testing.expectf(t, req.method == method, "%s: got %v", name, req.method)
	}
}

@(test)
params_are_extracted :: proc(t: ^testing.T) {
	{
		msg, _ := decode(`{"type":"request","id":3,"method":"scene.set","params":{"sceneId":"abc"}}`)
		req := msg.(Request)
		testing.expect_value(t, req.id, 3)
		testing.expect_value(t, req.params.(Params_Scene_Set).scene_id, "abc")
	}
	{
		msg, _ := decode(`{"type":"request","id":4,"method":"audio.setMute","params":{"sourceId":"mic","muted":true}}`)
		p := msg.(Request).params.(Params_Mute)
		testing.expect_value(t, p.source_id, "mic")
		testing.expect_value(t, p.muted, true)
	}
	{
		msg, _ := decode(`{"type":"request","id":5,"method":"audio.toggleMute","params":{"sourceId":"mic"}}`)
		p := msg.(Request).params.(Params_Mute)
		testing.expect_value(t, p.source_id, "mic")
		testing.expect_value(t, p.muted, nil)
	}
	{
		msg, _ := decode(`{"type":"request","id":6,"method":"audio.setVolume","params":{"sourceId":"mic","volume":0.25}}`)
		p := msg.(Request).params.(Params_Volume)
		testing.expect_value(t, p.volume, 0.25)
	}
	{
		msg, _ := decode(`{"type":"request","id":7,"method":"source.toggleVisible","params":{"sceneId":"s","sourceId":"a"}}`)
		p := msg.(Request).params.(Params_Visible)
		testing.expect_value(t, p.scene_id, "s")
		testing.expect_value(t, p.source_id, "a")
		testing.expect_value(t, p.visible, nil)
	}
}

@(test)
volume_accepts_whole_numbers :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"audio.setVolume","params":{"sourceId":"a","volume":1}}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params.(Params_Volume).volume, 1)
}

@(test)
out_of_range_volume_reaches_dispatch :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"audio.setVolume","params":{"sourceId":"a","volume":1.5}}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params.(Params_Volume).volume, 1.5)
}

@(test)
topics_are_collected :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"events.subscribe","params":{"events":["scene","audio","scene"]}}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params.(Params_Subscribe).topics, Topic_Set{.Scene, .Audio})
}

@(test)
empty_topic_list_clears :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"events.subscribe","params":{"events":[]}}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params.(Params_Subscribe).topics, Topic_Set{})
}

@(test)
large_id_survives :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":9007199254740991,"method":"state.get"}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).id, 9007199254740991)
}

@(test)
unknown_keys_are_ignored :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"scene.set","params":{"sceneId":"s","futureKey":5},"extra":true}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params.(Params_Scene_Set).scene_id, "s")
}

@(test)
unanswerable_faults_carry_no_id :: proc(t: ^testing.T) {
	expect_fault(t, `not json at all`, .Bad_Request)
	expect_fault(t, `[1,2,3]`, .Bad_Request)
	expect_fault(t, `{"id":1,"method":"state.get"}`, .Bad_Request)
	expect_fault(t, `{"type":"greeting"}`, .Bad_Request)
	expect_fault(t, `{"type":"request","method":"state.get"}`, .Bad_Request)
	expect_fault(t, `{"type":"request","id":"seven","method":"state.get"}`, .Bad_Request)
	expect_fault(t, `{"type":"request","id":1.5,"method":"state.get"}`, .Bad_Request)
	expect_fault(t, `{"type":"hello"}`, .Bad_Request)
	expect_fault(t, `{"type":"hello","protocol":"one"}`, .Bad_Request)
}

@(test)
answerable_faults_carry_the_id :: proc(t: ^testing.T) {
	expect_fault(t, `{"type":"request","id":9}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"scene.explode"}`, .Unknown_Method, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"scene.set"}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"scene.set","params":{}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"scene.set","params":[]}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"scene.set","params":{"sceneId":5}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"audio.setMute","params":{"sourceId":"a"}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"audio.setMute","params":{"sourceId":"a","muted":"yes"}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"audio.setVolume","params":{"sourceId":"a","volume":"loud"}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"source.setVisible","params":{"sceneId":"s","sourceId":"a"}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"events.subscribe","params":{}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"events.subscribe","params":{"events":"scene"}}`, .Bad_Request, 9)
	expect_fault(t, `{"type":"request","id":9,"method":"events.subscribe","params":{"events":[5]}}`, .Bad_Request, 9)
}

@(test)
unknown_topic_is_invalid_argument :: proc(t: ^testing.T) {
	expect_fault(t, `{"type":"request","id":2,"method":"events.subscribe","params":{"events":["scene","weather"]}}`, .Invalid_Argument, 2)
}

@(test)
methods_without_params_ignore_them :: proc(t: ^testing.T) {
	msg, fault := decode(`{"type":"request","id":1,"method":"recording.toggle","params":{"stray":true}}`)
	testing.expect_value(t, fault, nil)
	testing.expect_value(t, msg.(Request).params, nil)
}
