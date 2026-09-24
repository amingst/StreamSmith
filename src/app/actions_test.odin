// src/app/actions_test.odin
package app

import "core:crypto"
import "core:math"
import "core:strings"
import "core:testing"

import "../action"
import "../config"
import "../show"

// A show with one scene, one audio source (placed twice) and one image source.
// No devices are opened: dispatch only edits the show data.
@(private="file")
Fixture :: struct {
	show_cfg:     show.Show,
	output:       Output_State,
	active_scene: string,
	ctx:          Dispatch_Context,
	scene_id:     string,
	mic_id:       string,
	image_id:     string,
}

@(private="file")
fixture_init :: proc(f: ^Fixture) {
	context.random_generator = crypto.random_generator() // show ids are UUID v4
	f.show_cfg = show.create_default()
	f.scene_id = show.create_scene(&f.show_cfg, "Main")
	f.mic_id = show.create_source(&f.show_cfg, "Mic", show.Audio_Source_Data{params = {volume = 1}})
	f.image_id = show.create_source(&f.show_cfg, "Logo", show.Image_Source_Data{})
	sc := show.find_scene(&f.show_cfg, f.scene_id)
	show.place_source(sc, f.mic_id)
	show.place_source(sc, f.mic_id)
	f.ctx = Dispatch_Context{
		output          = &f.output,
		show_cfg        = &f.show_cfg,
		active_scene_id = &f.active_scene,
	}
}

@(private="file")
dispatch :: proc(f: ^Fixture, a: action.Action) -> Action_Result {
	env := action.Envelope{action = a, origin = .UI}
	return dispatch_action(&env, &f.ctx)
}

@(test)
toggle_and_set_mute :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)

	r := dispatch(&f, action.Action_Toggle_Mute{source_id = f.mic_id})
	testing.expect_value(t, r.error, Action_Error.None)
	testing.expect_value(t, r.value, Maybe(bool)(true))
	r = dispatch(&f, action.Action_Toggle_Mute{source_id = f.mic_id})
	testing.expect_value(t, r.value, Maybe(bool)(false))

	r = dispatch(&f, action.Action_Set_Mute{source_id = f.mic_id, muted = true})
	r = dispatch(&f, action.Action_Set_Mute{source_id = f.mic_id, muted = true})
	testing.expect_value(t, r.value, Maybe(bool)(true))

	r = dispatch(&f, action.Action_Toggle_Mute{source_id = "missing"})
	testing.expect_value(t, r.error, Action_Error.Not_Found)
	r = dispatch(&f, action.Action_Toggle_Mute{source_id = f.image_id})
	testing.expect_value(t, r.error, Action_Error.Invalid_Argument)
}

@(test)
set_volume_rejects_out_of_range :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)
	mic := &show.find_source(&f.show_cfg, f.mic_id).data.(show.Audio_Source_Data)

	r := dispatch(&f, action.Action_Set_Volume{source_id = f.mic_id, volume = 0.25})
	testing.expect_value(t, r.error, Action_Error.None)
	testing.expect_value(t, mic.volume, 0.25)

	for bad in ([]f32{1.5, -0.1, math.nan_f32()}) {
		r = dispatch(&f, action.Action_Set_Volume{source_id = f.mic_id, volume = bad})
		testing.expect_value(t, r.error, Action_Error.Invalid_Argument)
		testing.expect_value(t, mic.volume, 0.25)
	}
}

@(test)
visibility_applies_to_every_placement :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)
	sc := show.find_scene(&f.show_cfg, f.scene_id)
	sc.sources[1].visible = false // out of sync on purpose

	r := dispatch(&f, action.Action_Toggle_Source_Visible{scene_id = f.scene_id, source_id = f.mic_id})
	testing.expect_value(t, r.error, Action_Error.None)
	testing.expect_value(t, r.value, Maybe(bool)(false))
	for p in sc.sources do testing.expect_value(t, p.visible, false)

	r = dispatch(&f, action.Action_Set_Source_Visible{scene_id = f.scene_id, source_id = f.mic_id, visible = true})
	testing.expect_value(t, r.value, Maybe(bool)(true))
	for p in sc.sources do testing.expect_value(t, p.visible, true)

	r = dispatch(&f, action.Action_Set_Source_Visible{scene_id = f.scene_id, source_id = f.image_id, visible = true})
	testing.expect_value(t, r.error, Action_Error.Not_Found)
	r = dispatch(&f, action.Action_Toggle_Source_Visible{scene_id = "missing", source_id = f.mic_id})
	testing.expect_value(t, r.error, Action_Error.Not_Found)
}

@(test)
set_scene_stores_show_owned_id :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)

	r := dispatch(&f, action.Action_Set_Scene{scene_id = "missing"})
	testing.expect_value(t, r.error, Action_Error.Not_Found)
	testing.expect_value(t, f.active_scene, "")

	r = dispatch(&f, action.Action_Set_Scene{scene_id = f.scene_id})
	testing.expect_value(t, r.error, Action_Error.None)
	testing.expect_value(t, f.active_scene, f.scene_id)
	// An owned copy, so deleting the scene can't leave it dangling.
	testing.expect(t, raw_data(f.active_scene) != raw_data(show.find_scene(&f.show_cfg, f.scene_id).id))

	// Setting the live scene again is ok.
	r = dispatch(&f, action.Action_Set_Scene{scene_id = f.scene_id})
	testing.expect_value(t, r.error, Action_Error.None)
	delete(f.active_scene)
}

@(test)
ensure_active_scene_repairs :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)
	defer delete(f.active_scene)
	first_id := f.show_cfg.scenes[0].id

	// Startup: nothing active yet.
	ensure_active_scene(&f.active_scene, &f.show_cfg)
	testing.expect_value(t, f.active_scene, first_id)

	// A scene that isn't in the show (deleted, or from the previous show).
	delete(f.active_scene)
	f.active_scene = strings.clone("gone")
	ensure_active_scene(&f.active_scene, &f.show_cfg)
	testing.expect_value(t, f.active_scene, first_id)

	// A valid scene is left alone.
	r := dispatch(&f, action.Action_Set_Scene{scene_id = f.scene_id})
	testing.expect_value(t, r.error, Action_Error.None)
	ensure_active_scene(&f.active_scene, &f.show_cfg)
	testing.expect_value(t, f.active_scene, f.scene_id)

	// No scenes left.
	for len(f.show_cfg.scenes) > 0 do show.remove_scene(&f.show_cfg, 0)
	ensure_active_scene(&f.active_scene, &f.show_cfg)
	testing.expect_value(t, f.active_scene, "")
}

@(test)
output_starts_fail_before_touching_the_encoder :: proc(t: ^testing.T) {
	f: Fixture
	fixture_init(&f)
	defer show.destroy_show(&f.show_cfg)

	// No videos directory in the zeroed paths.
	paths: config.Paths
	f.ctx.paths = &paths
	r := dispatch(&f, action.Action_Start_Recording{})
	testing.expect_value(t, r.error, Action_Error.Not_Configured)

	f.output.recording = true
	r = dispatch(&f, action.Action_Start_Recording{})
	testing.expect_value(t, r.error, Action_Error.Already_Active)
	f.output.recording = false

	// Default output has no RTMP url/key.
	r = dispatch(&f, action.Action_Start_Streaming{})
	testing.expect_value(t, r.error, Action_Error.Not_Configured)
	f.output.streaming = true
	r = dispatch(&f, action.Action_Start_Streaming{})
	testing.expect_value(t, r.error, Action_Error.Already_Active)
	f.output.streaming = false

	// Stops while idle are ok.
	testing.expect_value(t, dispatch(&f, action.Action_Stop_Recording{}).error, Action_Error.None)
	testing.expect_value(t, dispatch(&f, action.Action_Stop_Streaming{}).error, Action_Error.None)
}
