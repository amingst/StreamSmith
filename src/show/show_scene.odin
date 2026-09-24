package show

import "core:log"
import "core:strings"

Show_Source_Placement :: struct {
	id: string, // UUID v4
	source_id: string, // UUID v4
	x, y, w, h: f32, // X and Y positions, width and height
	order: int, // layer order
	color: [4]f32,
	visible: bool, // whether this placement is shown in this scene
	mute_override: bool, // Whether the show mutes the source on the scene
}

Show_Scene :: struct {
	id: string, // UUID v4
	name: string, // display name
	order: int, // layer order
	sources: [dynamic]Show_Source_Placement,
}

create_scene :: proc(s: ^Show, name: string) -> string {
	id := new_id()
	append(&s.scenes, Show_Scene{
		id    = id,
		name  = strings.clone(name),
		order = len(s.scenes),
	})
	log.debugf("show scene created: id=%v name=%q", id, name)
	return id
}

remove_scene :: proc(s: ^Show, index: int) -> string {
	log.debugf("show scene deleted: id=%v name=%q placements=%v",
		s.scenes[index].id, s.scenes[index].name, len(s.scenes[index].sources))
	removed_id := s.scenes[index].id
	destroy_scene(&s.scenes[index])
	ordered_remove(&s.scenes, index)

	// Keep `order` dense and matching position.
	for &sc, i in s.scenes {
		sc.order = i
	}

	return removed_id
}

// Places an existing show source into a scene at default geometry. Placing
// the same source_id into multiple scenes is the point -- each placement is
// its own position/visibility/mute, the source identity stays shared.
// The placement owns a copy of source_id (destroy_placement frees it).
place_source :: proc(sc: ^Show_Scene, source_id: string) -> string {
	id := new_id()
	append(&sc.sources, Show_Source_Placement{
		id        = id,
		source_id = strings.clone(source_id),
		x = 100, y = 100, w = 400, h = 300,
		order   = len(sc.sources),
		color   = {0.9, 0.3, 0.2, 1.0},
		visible = true,
	})
	log.debugf("show source %v placed in scene %v", source_id, sc.id)
	return id
}

// Removes a placement from a scene. The underlying Show_Source is untouched
// -- it may still be placed in other scenes, or kept around unplaced for
// later reuse. There is currently no UI to delete a Show_Source outright.
remove_placement :: proc(sc: ^Show_Scene, index: int) -> string {
	removed_id := sc.sources[index].id
	destroy_placement(&sc.sources[index])
	ordered_remove(&sc.sources, index)
	return removed_id
}

find_placement :: proc(sc: ^Show_Scene, id: string) -> ^Show_Source_Placement {
	for &p in sc.sources {
		if p.id == id {
			return &p
		}
	}
	return nil
}

destroy_placement :: proc(p: ^Show_Source_Placement) {
	if p == nil do return
	delete(p.id)
	delete(p.source_id)
}

destroy_scene :: proc(s: ^Show_Scene) {
	if s == nil do return
	for &p in s.sources {
		destroy_placement(&p)
	}
	delete(s.sources)
	delete(s.id)
	delete(s.name)
}
