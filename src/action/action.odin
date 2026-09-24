package action

import "core:mem"
import "core:strings"

Action_Start_Recording :: struct {}
Action_Toggle_Recording :: struct {}
Action_Stop_Recording :: struct {}
Action_Start_Streaming :: struct {}
Action_Toggle_Streaming :: struct {}
Action_Stop_Streaming :: struct {}
Action_Set_Scene :: struct {
	scene_id: string,
}
Action_Set_Mute :: struct {
	source_id: string,
	muted: bool,
}
Action_Toggle_Mute :: struct {
	source_id: string,
}
Action_Set_Volume :: struct {
	source_id: string,
	volume: f32,
}
Action_Set_Source_Visible :: struct {
	scene_id: string,
	source_id: string,
	visible: bool,
}
Action_Toggle_Source_Visible :: struct {
	scene_id: string,
	source_id: string,
}

Action :: union {
	Action_Start_Recording,
	Action_Stop_Recording,
	Action_Toggle_Recording,
	Action_Start_Streaming,
	Action_Stop_Streaming,
	Action_Toggle_Streaming,
	Action_Set_Scene,
	Action_Set_Mute,
	Action_Toggle_Mute,
	Action_Set_Volume,
	Action_Set_Source_Visible,
	Action_Toggle_Source_Visible,
}

@(private)
clone_action_strings :: proc(a: ^Action, allocator: mem.Allocator) {
	switch &v in a {
	case Action_Set_Scene:
		v.scene_id = strings.clone(v.scene_id, allocator)
	case Action_Set_Mute:
		v.source_id = strings.clone(v.source_id, allocator)
	case Action_Toggle_Mute:
		v.source_id = strings.clone(v.source_id, allocator)
	case Action_Set_Volume:
		v.source_id = strings.clone(v.source_id, allocator)
	case Action_Set_Source_Visible:
		v.scene_id  = strings.clone(v.scene_id, allocator)
		v.source_id = strings.clone(v.source_id, allocator)
	case Action_Toggle_Source_Visible:
		v.scene_id  = strings.clone(v.scene_id, allocator)
		v.source_id = strings.clone(v.source_id, allocator)
	case Action_Start_Recording, Action_Stop_Recording, Action_Toggle_Recording,
	     Action_Start_Streaming, Action_Stop_Streaming, Action_Toggle_Streaming:
		// no strings
	}
}

@(private)
free_action_strings :: proc(a: ^Action, allocator: mem.Allocator) {
	switch &v in a {
	case Action_Set_Scene:
		delete(v.scene_id, allocator)
	case Action_Set_Mute:
		delete(v.source_id, allocator)
	case Action_Toggle_Mute:
		delete(v.source_id, allocator)
	case Action_Set_Volume:
		delete(v.source_id, allocator)
	case Action_Set_Source_Visible:
		delete(v.scene_id, allocator)
		delete(v.source_id, allocator)
	case Action_Toggle_Source_Visible:
		delete(v.scene_id, allocator)
		delete(v.source_id, allocator)
	case Action_Start_Recording, Action_Stop_Recording, Action_Toggle_Recording,
	     Action_Start_Streaming, Action_Stop_Streaming, Action_Toggle_Streaming:
		// no strings
	}
}
