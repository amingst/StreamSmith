package remote

import "../action"
import "protocol"

// Turns a decoded request into the action the main loop dispatches. Pure, so
// the mapping can be tested without sockets.
//
// state.get and events.subscribe never reach the queue -- the reader answers
// them from the published snapshot and the client's own topic set -- so they
// map to nil. Toggles stay toggles: they resolve during dispatch, on main-loop
// state, so a Deck press can't act on a stale value.
request_to_action :: proc(method: protocol.Method, params: protocol.Params) -> action.Action {
	switch method {
	case .State_Get, .Events_Subscribe:
		return nil

	case .Scene_Set:
		return action.Action_Set_Scene{scene_id = params.(protocol.Params_Scene_Set).scene_id}

	case .Recording_Start:  return action.Action_Start_Recording{}
	case .Recording_Stop:   return action.Action_Stop_Recording{}
	case .Recording_Toggle: return action.Action_Toggle_Recording{}
	case .Streaming_Start:  return action.Action_Start_Streaming{}
	case .Streaming_Stop:   return action.Action_Stop_Streaming{}
	case .Streaming_Toggle: return action.Action_Toggle_Streaming{}

	case .Audio_Set_Mute:
		p := params.(protocol.Params_Mute)
		return action.Action_Set_Mute{source_id = p.source_id, muted = p.muted.? or_else false}

	case .Audio_Toggle_Mute:
		return action.Action_Toggle_Mute{source_id = params.(protocol.Params_Mute).source_id}

	case .Audio_Set_Volume:
		p := params.(protocol.Params_Volume)
		return action.Action_Set_Volume{source_id = p.source_id, volume = p.volume}

	case .Source_Set_Visible:
		p := params.(protocol.Params_Visible)
		return action.Action_Set_Source_Visible{
			scene_id  = p.scene_id,
			source_id = p.source_id,
			visible   = p.visible.? or_else false,
		}

	case .Source_Toggle_Visible:
		p := params.(protocol.Params_Visible)
		return action.Action_Toggle_Source_Visible{scene_id = p.scene_id, source_id = p.source_id}
	}
	return nil
}
