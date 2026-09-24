package protocol

PROTOCOL_VERSION :: 1

// Close codes, see docs/remote-protocol.md section 11.
CLOSE_GOING_AWAY          :: 1001
CLOSE_UNSUPPORTED_DATA    :: 1003 // binary frame
CLOSE_HANDSHAKE_REQUIRED  :: 4000 // first message wasn't a valid hello
CLOSE_UNSUPPORTED_VERSION :: 4001

Error_Code :: enum {
	Bad_Request,
	Unknown_Method,
	Unsupported_Protocol,
	Not_Found,
	Invalid_Argument,
	Already_Active,
	Not_Configured,
	Failed,
}

error_code_names := [Error_Code]string{
	.Bad_Request          = "bad_request",
	.Unknown_Method       = "unknown_method",
	.Unsupported_Protocol = "unsupported_protocol",
	.Not_Found            = "not_found",
	.Invalid_Argument     = "invalid_argument",
	.Already_Active       = "already_active",
	.Not_Configured       = "not_configured",
	.Failed               = "failed",
}

Topic :: enum {
	Scene,
	Outputs,
	Audio,
	Sources,
	Show,
}

Topic_Set :: bit_set[Topic]

topic_names := [Topic]string{
	.Scene   = "scene",
	.Outputs = "outputs",
	.Audio   = "audio",
	.Sources = "sources",
	.Show    = "show",
}

Method :: enum {
	State_Get,
	Events_Subscribe,
	Scene_Set,
	Recording_Start,
	Recording_Stop,
	Recording_Toggle,
	Streaming_Start,
	Streaming_Stop,
	Streaming_Toggle,
	Audio_Set_Mute,
	Audio_Toggle_Mute,
	Audio_Set_Volume,
	Source_Set_Visible,
	Source_Toggle_Visible,
}

method_names := [Method]string{
	.State_Get             = "state.get",
	.Events_Subscribe      = "events.subscribe",
	.Scene_Set             = "scene.set",
	.Recording_Start       = "recording.start",
	.Recording_Stop        = "recording.stop",
	.Recording_Toggle      = "recording.toggle",
	.Streaming_Start       = "streaming.start",
	.Streaming_Stop        = "streaming.stop",
	.Streaming_Toggle      = "streaming.toggle",
	.Audio_Set_Mute        = "audio.setMute",
	.Audio_Toggle_Mute     = "audio.toggleMute",
	.Audio_Set_Volume      = "audio.setVolume",
	.Source_Set_Visible    = "source.setVisible",
	.Source_Toggle_Visible = "source.toggleVisible",
}

Event_Name :: enum {
	Scene_Changed,
	Scenes_List_Changed,
	Recording_Changed,
	Streaming_Changed,
	Audio_Mute_Changed,
	Audio_Volume_Changed,
	Source_Visibility_Changed,
	Sources_List_Changed,
	Show_Changed,
}

event_names := [Event_Name]string{
	.Scene_Changed             = "scene.changed",
	.Scenes_List_Changed       = "scenes.listChanged",
	.Recording_Changed         = "recording.changed",
	.Streaming_Changed         = "streaming.changed",
	.Audio_Mute_Changed        = "audio.muteChanged",
	.Audio_Volume_Changed      = "audio.volumeChanged",
	.Source_Visibility_Changed = "source.visibilityChanged",
	.Sources_List_Changed      = "sources.listChanged",
	.Show_Changed              = "show.changed",
}

event_topics := [Event_Name]Topic{
	.Scene_Changed             = .Scene,
	.Scenes_List_Changed       = .Scene,
	.Recording_Changed         = .Outputs,
	.Streaming_Changed         = .Outputs,
	.Audio_Mute_Changed        = .Audio,
	.Audio_Volume_Changed      = .Audio,
	.Source_Visibility_Changed = .Sources,
	.Sources_List_Changed      = .Sources,
	.Show_Changed              = .Show,
}

method_from_string :: proc(s: string) -> (Method, bool) {
	for name, m in method_names {
		if name == s do return m, true
	}
	return {}, false
}

topic_from_string :: proc(s: string) -> (Topic, bool) {
	for name, topic in topic_names {
		if name == s do return topic, true
	}
	return {}, false
}
