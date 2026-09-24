package protocol

Snapshot :: struct {
	show:            Snapshot_Show,
	active_scene_id: Maybe(string) `json:"activeSceneId"`,
	scenes:          []Snapshot_Scene,
	sources:         []Snapshot_Source,
	outputs:         Snapshot_Outputs,
}

Snapshot_Show :: struct {
	id:   string,
	name: string,
}

Snapshot_Scene :: struct {
	id:      string,
	name:    string,
	sources: []Snapshot_Placement,
}

Snapshot_Placement :: struct {
	source_id: string `json:"sourceId"`,
	visible:   bool,
}

Snapshot_Source :: struct {
	id:    string,
	name:  string,
	kind:  string,
	audio: Maybe(Snapshot_Audio) `json:"audio,omitempty"`,
}

Snapshot_Audio :: struct {
	muted:  bool,
	volume: f32,
}

Snapshot_Outputs :: struct {
	recording:  bool,
	finalizing: bool,
	streaming:  bool,
}

SOURCE_KIND_AUDIO_INPUT  :: "audio_input"
SOURCE_KIND_AUDIO_OUTPUT :: "audio_output"
SOURCE_KIND_CAMERA       :: "camera"
SOURCE_KIND_COLOR        :: "color"
SOURCE_KIND_DISPLAY      :: "display"
SOURCE_KIND_IMAGE        :: "image"
SOURCE_KIND_WINDOW       :: "window"
