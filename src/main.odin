package streamsmith

// @(require) keeps core:mem legal under -vet in non-debug builds.
import "core:fmt"
import "core:log"
@(require) import "core:mem"
import win32 "core:sys/windows"
import "vendor:directx/dxgi"
import "vendor:directx/d3d11"
import im      "libs:odin-imgui"
import imwin32 "libs:odin-imgui/backends/win32"
import imdx11  "libs:odin-imgui/backends/dx11"
import mf      "libs:mf"
import "libs:wic"
import "libs:wgc"
import time "core:time"

// Import from platform module
import "action"
import "app"
import "remote"
import "config"
import "platform"
import "render"
import "show"
import "ui"
import "capture"
import "audio"
import "encode"
import "rtmp"
import "mp4"
import "applog"

import "core:sys/windows"

// Drains and logs the D3D11 debug layer's message queue.
@(private = "file")
drain_d3d11_debug_layer :: proc(device: ^d3d11.IDevice) {
	info_queue: ^d3d11.IInfoQueue
	if hr := device->QueryInterface(d3d11.IInfoQueue_UUID, (^rawptr)(&info_queue)); hr < 0 {
		return
	}
	defer info_queue->Release()

	n := info_queue->GetNumStoredMessages()
	for i: u64 = 0; i < n; i += 1 {
		size: d3d11.SIZE_T
		if hr := info_queue->GetMessage(i, nil, &size); hr < 0 || size == 0 {
			continue
		}
		buf := make([]u8, int(size), context.temp_allocator)
		msg := (^d3d11.MESSAGE)(raw_data(buf))
		if hr := info_queue->GetMessage(i, msg, &size); hr < 0 {
			continue
		}
		switch msg.Severity {
		case .CORRUPTION, .ERROR:
			log.errorf("d3d11 debug layer: %s", msg.pDescription)
		case .WARNING:
			log.warnf("d3d11 debug layer: %s", msg.pDescription)
		case .INFO, .MESSAGE:
			log.infof("d3d11 debug layer: %s", msg.pDescription)
		}
	}
	info_queue->ClearStoredMessages()
}

main :: proc() {
	// Leak/bad-free tracking allocator, debug builds only.
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintfln("=== %v allocation(s) not freed: ===", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintfln("  %v bytes @ %v", entry.size, entry.location)
				}
			}
			if len(track.bad_free_array) > 0 {
				fmt.eprintfln("=== %v bad free(s): ===", len(track.bad_free_array))
				for entry in track.bad_free_array {
					fmt.eprintfln("  %p @ %v", entry.memory, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	// Set up logging -- console logger to stderr, debug level in debug builds.
	log_sink := applog.sink_init(8192)
	defer applog.sink_destroy(log_sink)

	main_log_ctx := applog.Log_Context{sink = log_sink, tag = {.Main, 0}}
	context.logger = applog.make_logger(&main_log_ctx)

	// Audio capture thread logs through this same sink.
	audio.set_log_sink(log_sink)

	// Config locations and persisted state.
	paths, _ := config.resolve_paths()
	defer config.destroy_paths(&paths)

	app.open_log_file(log_sink, &paths)

	app_cfg := app.load_app_config(&paths)
	defer config.destroy_app_config(&app_cfg)

	// Active show -- same load-active/pick-first/create-Default shape as the
	// old profiles/collections had, but no migration from either (there isn't
	// a legacy concept to migrate from anymore). Loaded early since the
	// preview target below needs its canvas dimensions.
	show_cfg, show_infos := app.load_show(&paths, &app_cfg)
	defer show.destroy_show(&show_cfg)
	defer show.destroy_infos(show_infos)

	// Make process DPI aware and obtain main monitor scale
	imwin32.EnableDpiAwareness()
	main_scale := imwin32.GetDpiScaleForMonitor(
		win32.MonitorFromPoint(win32.POINT{0, 0}, .MONITOR_DEFAULTTOPRIMARY))

    win: platform.Window
    window_title := fmt.tprintf("StreamSmith %s", APP_VERSION)
    if (!platform.create_window(&win, window_title, 1280, 800)) {
        log.fatal("window/device creation failed, exiting")
        return
    }
    defer platform.destroy_window(&win)
    win.msg_hook = imwin32.WndProcHandler

	// Offscreen target the scene is composited into, sized from the loaded show.
	preview_target, target_ok := render.create_target(
		win.device, u32(show_cfg.video.canvas_width), u32(show_cfg.video.canvas_height))
	if !target_ok {
		log.fatal("preview target creation failed, exiting (cause logged above)")
		return
	}
	defer render.destroy_target(&preview_target)

	// Seed applied state from the show the target was just sized from.
	applied := Applied{video = show_cfg.video}

	pipeline, pok := render.create_pipeline(win.device)
	if !pok do return
	defer render.destroy_pipeline(&pipeline)

	// Show the window
	win32.ShowWindow(win.hwnd, win32.SW_SHOWDEFAULT)
	win32.UpdateWindow(win.hwnd)

	// Setup Dear ImGui context
	im.CHECKVERSION()
	im.CreateContext()
	log.debug("ImGui context created")
	defer {
		im.DestroyContext()
		log.debug("ImGui context destroyed")
	}

	io := im.GetIO()
	io.ConfigFlags |= {
		.NavEnableKeyboard, // Enable Keyboard Controls
		.NavEnableGamepad,  // Enable Gamepad Controls
		.DockingEnable,     // Enable Docking
		.ViewportsEnable,   // Enable Multi-Viewport / Platform Windows
	}
	// io.ConfigViewportsNoAutoMerge = true
	// io.ConfigViewportsNoTaskBarIcon = true
	// io.ConfigDockingAlwaysTabBar = true
	// io.ConfigDockingTransparentPayload = true

	// Setup Dear ImGui style and fonts (unscaled; DPI scaling is applied below)
	ui.apply_theme()
	ui.load_fonts()

	// Setup scaling
	style := im.GetStyle()
	im.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale
	io.ConfigDpiScaleFonts = true     // [Experimental]
	io.ConfigDpiScaleViewports = true // [Experimental]

	// Match platform windows to regular ones when viewports are enabled.
	if .ViewportsEnable in io.ConfigFlags {
		style.WindowRounding = 0.0
		style.Colors[im.Col.WindowBg].w = 1.0
	}

	// Setup Platform/Renderer backends
	if !imwin32.Init(win.hwnd) {
		log.fatal("ImGui Win32 backend initialization failed")
		return
	}
	defer imwin32.Shutdown()
	if !imdx11.Init(win.device, win.device_context) {
		log.fatal("ImGui DirectX11 backend initialization failed")
		return
	}
	defer imdx11.Shutdown()
	log.info("ImGui backends initialised")

	outputs := capture.enumerate_outputs(win.device)
	defer capture.destroy_outputs(outputs)
	capture.log_device_adapter(win.device)

	audio_devices := audio.enumerate_devices()
	defer audio.destroy_devices(audio_devices)
	defer audio.shutdown()
	for dev in audio_devices {
		audio.log_device_format(dev)
	}

	// One-shot camera probe: start device 0 briefly to confirm capture works.
	enum_attrs: ^mf.IMFAttributes
    hr := mf.MFCreateAttributes(&enum_attrs, 1)
    if hr < 0 {
        log.errorf("cam probe: MFCreateAttributes failed: 0x%08X", u32(hr))
    } else {
        defer enum_attrs->Release()
        enum_attrs->SetGUID(
            &mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE,
            &mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID,
        )

        activates: [^]^mf.IMFActivate
        count:     u32
        hr = mf.MFEnumDeviceSources(enum_attrs, &activates, &count)
        if hr < 0 {
            log.errorf("cam probe: MFEnumDeviceSources failed: 0x%08X", u32(hr))
        } else if count == 0 {
            log.info("cam probe: no video devices")
        } else {
            defer {
                for i in 0..<count {
                    activates[i]->Release()
                }
                windows.CoTaskMemFree(activates)
            }

            // Pull the symbolic link off device 0.
            raw:     [^]u16
            raw_len: u32
            hr = activates[0]->GetAllocatedString(
                &mf.MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK,
                &raw, &raw_len,
            )
            if hr < 0 {
                log.errorf("cam probe: GetAllocatedString failed: 0x%08X", u32(hr))
            } else {
                defer windows.CoTaskMemFree(raw)

                symlink := raw[:raw_len]

                log.infof("cam probe: device 0 symlink len=%d", raw_len)

                cam := capture.camera_start(symlink, log_sink, 0)
                time.sleep(500 * time.Millisecond)
                capture.camera_stop(cam)
            }
        }
    }

	// WinRT apartment setup for window capture; expects S_FALSE (already STA).
	{
		hr = wgc.RoInitialize(wgc.RO_INIT_SINGLETHREADED)
		if hr < 0 {
			log.errorf("RoInitialize failed: 0x%08X", u32(hr))
			if hr == wgc.RPC_E_CHANGED_MODE {
				log.error("RoInitialize: apartment is MTA, expected STA — WinRT capture will not work")
			}
			return
		}
		if hr == 0 {
			log.warnf("RoInitialize returned S_OK (0x%08X) — expected S_FALSE; check init ordering", u32(hr))
		} else {
			log.infof("RoInitialize: 0x%08X", u32(hr))
		}
	}

	if !wic.wic_init() {
		log.error("WIC factory creation failed (cause logged above)")
	}
	defer wic.wic_shutdown()

	hr = mf.MFStartup(mf.MF_VERSION, mf.MFSTARTUP_FULL)
	if hr < 0 {
		log.errorf("MFStartup failed: 0x%08X", u32(hr))
		return
	}
	defer mf.MFShutdown()

	// Audio mixer runs on its own thread so a render-loop stall can't stall
	// the audio timeline. Stopped (via defer) before audio.shutdown() closes
	// the streams it reads from.
	mix_thread: audio.Mix_Thread
	if !audio.mix_thread_start(&mix_thread) {
		log.error("could not start the audio mixer thread")
		return
	}
	defer audio.mix_thread_stop(&mix_thread)

	// Per-second audio instrumentation — diffs against previous snapshot.
	audio_diag_last_tick := time.tick_now()
	audio_diag_last_blocks: u64
	audio_diag_last_aac_recv: u64
	audio_diag_last_ps_attempted: u64
	audio_diag_last_ps_dropped: u64

	// Must run and tear down while the WinRT apartment is still alive -- see
	// wgc_init below for the matching ordering constraint on the way out.
	defer wgc.RoUninitialize()

	// wgc_init creates the process-lifetime HSTRINGs window capture needs.
	if !wgc.wgc_init() {
		log.error("wgc_init failed (cause logged above); window capture will not work")
	}
	defer wgc.wgc_shutdown()

	// UI, and later hotkeys and the remote server, push actions here; the main
	// loop dispatches them once per frame.
	actions: action.Envelope_Queue
	action.queue_init(&actions)
	action_batch := make([dynamic]action.Envelope, 0, 16, actions.allocator)
	defer action.queue_destroy(&actions, &action_batch)

	// Owned; set by Set_Scene and repaired by app.ensure_active_scene.
	active_scene_id: string
	defer delete(active_scene_id)

	// Remote control. The server pushes onto the same queue as the UI, so it
	// must stop before the queue (and before the show and audio) goes away --
	// this defer is registered after the queue's, so it runs first.
	remote_server: remote.Server
	remote_running := false
	defer if remote_running do remote.server_stop(&remote_server)

	// Answers remote requests and turns each frame's state change into events.
	// With no server it does nothing.
	remote_bridge: app.Remote_Bridge
	app.bridge_init(&remote_bridge, nil)
	defer app.bridge_destroy(&remote_bridge)

	start_remote(&remote_server, &remote_running, &remote_bridge, &app_cfg.remote, &actions)

    ui_state := ui.init_state(APP_VERSION, &actions)
	clear_color := im.Vec4{0.45, 0.55, 0.60, 1.00}
    defer ui.destroy(&ui_state)

    done := false
	was_occluded := false

	output: app.Output_State

	frame_bytes := make([]u8, int(preview_target.width) * int(preview_target.height) * 4)

	// Main loop
	for !done {
		drain_d3d11_debug_layer(win.device)

		// Poll and handle messages (inputs, window resize, etc.)
        if platform.pump_messages(&win) {
            break
        }

		// Handle window being minimized or screen locked
		if win.swap_chain_occluded && win.swap_chain->Present(0, {.TEST}) == dxgi.STATUS_OCCLUDED {
			if !was_occluded {
				log.debug("swap chain occluded, throttling to 10ms poll")
				was_occluded = true
			}
			win32.Sleep(10)
			continue
		}
		if was_occluded {
			log.debug("occlusion cleared, resuming rendering")
			was_occluded = false
		}
		win.swap_chain_occluded = false

		// Handle window resize (we don't resize directly in the WM_SIZE handler)
		if win.resize_width != 0 && win.resize_height != 0 {
			log.debugf("swapchain resize %vx%v", win.resize_width, win.resize_height)
			platform.cleanup_render_target(&win)
			hr = win.swap_chain->ResizeBuffers(0, win.resize_width, win.resize_height, .UNKNOWN, {})
			if hr < 0 {
				log.errorf("ResizeBuffers failed: HRESULT 0x%08X", u32(hr))
			}
			win.resize_width, win.resize_height = 0, 0
			platform.create_render_target(&win)
		}

		// Bring live objects in line with the settings modal -- see reconcile.odin.
		reconcile(&applied, &show_cfg, win.device, &preview_target, output.recording || output.streaming || output.finalizing_sink != nil)

		// Check each frame for resize after each reconcile call
		needed := int(preview_target.width) * int(preview_target.height) * 4
		if len(frame_bytes) != needed {
			delete(frame_bytes)
			frame_bytes = make([]u8, needed)
		}

		// Service a pending save, one frame after the request so show_cfg is settled by reconcile first.
		if trigger := ui_state.settings.save_request; trigger != .None {
			ui_state.settings.save_request = .None
			if paths.shows != "" {
				log.infof("save requested (%v)", trigger)
				show.save_show(paths.shows, &show_cfg)
			} else {
				log.warnf("save requested (%v), but no config path is available", trigger)
			}
		}

		// The Remote tab edited app.json: persist it and bounce the server.
		if ui_state.settings.remote_dirty {
			ui_state.settings.remote_dirty = false
			if paths.app_config != "" {
				config.save_app_config(&app_cfg, paths.app_config)
			}
			start_remote(&remote_server, &remote_running, &remote_bridge, &app_cfg.remote, &actions)
		}

		// Service a pending show request.
		if req := ui_state.shows.request; req != .None {
			app.handle_show_request(req, &ui_state.shows, &show_cfg, &app_cfg, &paths, &show_infos)
		}

		// Dispatch queued actions. Runs after the show request, so actions aimed
		// at a show that was just switched away from fail with Not_Found.
		{
			pre_blocks := audio.mix_blocks_emitted()
			// Rebuilt each frame: a show switch replaces show_cfg.
			dispatch_ctx := app.Dispatch_Context{
				output          = &output,
				paths           = &paths,
				target          = &preview_target,
				show_cfg        = &show_cfg,
				active_scene_id = &active_scene_id,
				log_sink        = log_sink,
			}
			action.queue_drain(&actions, &action_batch)
			for &env in action_batch {
				result := app.dispatch_action(&env, &dispatch_ctx) // failures are logged by dispatch
				// Before the release: the reply handle and the action's
				// strings are still alive here.
				app.bridge_respond(&remote_bridge, &env, result)
			}
			action.queue_release(&actions, &action_batch)
			app.ensure_active_scene(&active_scene_id, &show_cfg)

			// Attaching a new encoder resets the block counter; reset diag snapshots to match.
			if audio.mix_blocks_emitted() < pre_blocks {
				audio_diag_last_blocks = 0
				audio_diag_last_aac_recv = 0
				audio_diag_last_ps_attempted = 0
				audio_diag_last_ps_dropped = 0
				audio_diag_last_tick = time.tick_now()
			}
		}

		// Reap a finalizing MP4 sink, and catch auto-stops on the active sink.
		if output.mp4_sink != nil && mp4.mp4_sink_is_stopped(output.mp4_sink) {
			log.warn("recording auto-stopped (spillover ceiling breach)")
			mp4.mp4_sink_reap(output.mp4_sink)
			output.mp4_sink = nil
			output.recording = false
			app.maybe_release_encoder(&output)
		}
		if output.finalizing_sink != nil && mp4.mp4_sink_is_stopped(output.finalizing_sink) {
			mp4.mp4_sink_reap(output.finalizing_sink)
			output.finalizing_sink = nil
			app.maybe_release_encoder(&output)
			log.info("recording finalized")
		}

		// Snapshot, events and the state.get copy. After the sink reaping above,
		// so a finished finalize is reported in the frame it happens.
		app.bridge_update(&remote_bridge, &show_cfg, active_scene_id, &output)

		// Neutral fallback clear color -- Show_Scene has no per-scene color
		// (that was a scene.Collection-only cosmetic, dropped in the show model).
		scene_clear := [4]f32{0.10, 0.10, 0.12, 1.0}

		// Composite the scene into the offscreen target before ImGui's frame starts.
		quads := make([dynamic]render.Quad, context.temp_allocator)
		inputs := make([dynamic]audio.Mix_Input, context.temp_allocator)
		show.service_show(&show_cfg, active_scene_id, win.device, win.device_context, log_sink, &quads, &inputs)
		render.draw_scene(win.device_context, &preview_target, &pipeline, quads[:], scene_clear)

		// -- Audio mixer --------------------------------------------------
		// Hand this frame's input list to the mixer thread; mixing itself
		// no longer happens here.
		audio.mix_publish_inputs(inputs[:])

		// Per-second audio instrumentation.
		if time.duration_seconds(time.tick_since(audio_diag_last_tick)) >= 1.0 {
			aac_recv: u64
			ps_attempted: u64
			ps_dropped: u64
			if output.mp4_sink != nil {
				aac_recv = output.mp4_sink.diag.put_audio_groups_received
				ps_attempted = output.mp4_sink.diag.audio_stats.attempted
				ps_dropped = output.mp4_sink.diag.audio_stats.other_fail
			} else {
				// No active sink — reset snapshots so the next sink starts clean.
				audio_diag_last_aac_recv = 0
				audio_diag_last_ps_attempted = 0
				audio_diag_last_ps_dropped = 0
			}
			blocks_now := audio.mix_blocks_emitted()
			d_blocks := blocks_now - audio_diag_last_blocks
			d_aac := aac_recv - audio_diag_last_aac_recv
			d_attempts := ps_attempted - audio_diag_last_ps_attempted
			d_drops := ps_dropped - audio_diag_last_ps_dropped
			if d_blocks > 0 || d_aac > 0 || d_attempts > 0 {
				log.infof("audio/sec: mixed_blocks=%v aac_to_sink=%v ps_attempts=%v ps_drops=%v",
					d_blocks, d_aac, d_attempts, d_drops)
			}
			audio_diag_last_blocks = blocks_now
			audio_diag_last_aac_recv = aac_recv
			audio_diag_last_ps_attempted = ps_attempted
			audio_diag_last_ps_dropped = ps_dropped
			audio_diag_last_tick = time.tick_now()
		}

		// -- Video push ---------------------------------------------------
		if output.recording || output.streaming {
			// flip_vertical works around MF's RGB32 bottom-up convention.
			read_ok := render.read_target(win.device_context, &preview_target, frame_bytes, flip_vertical = true)

			if !read_ok {
				log.warnf("read_target failed (recording=%v streaming=%v); frame_bytes left stale from the last successful read", output.recording, output.streaming)
			}

			if read_ok && output.enc != nil {
				encode.mailbox_put(output.enc.raw_mailbox, frame_bytes, preview_target.width, preview_target.height)
			}
		}
		// One-shot startup readback, for debugging the render pipeline.
		@static dumped := false
		if !dumped {
			buf := make([]u8, int(preview_target.width) * int(preview_target.height) * 4)
			defer delete(buf)
			if render.read_target(win.device_context, &preview_target, buf) {
				log.infof("readback: first pixel BGRA = %v %v %v %v", buf[0], buf[1], buf[2], buf[3])
			}
			dumped = true
		}

		ui.load_layout()

		// Start the Dear ImGui frame
		imdx11.NewFrame()
		imwin32.NewFrame()
		im.NewFrame()

        // Wrap the preview SRV as an already-uploaded backend texture.
        preview_tex := im.TextureRef{_TexID = im.TextureID(uintptr(preview_target.srv))}

        // Mirror output state into ui_state for the Controls panel to read.
        ui_state.controls.recording = output.recording
        ui_state.controls.streaming = output.streaming
        ui_state.controls.finalizing = output.finalizing_sink != nil
        ui_state.scenes.active_id = active_scene_id
        ui_state.settings.remote_status = remote_status_line(&app_cfg.remote, remote_running)

        ui.draw(&ui_state, &show_cfg, &app_cfg, &clear_color, preview_tex, outputs, show_infos,
            f32(preview_target.width), f32(preview_target.height), audio_devices)

		// Rendering
		im.Render()
		clear_color_with_alpha := [4]f32{
			clear_color.x * clear_color.w,
			clear_color.y * clear_color.w,
			clear_color.z * clear_color.w,
			clear_color.w,
		}
		win.device_context->OMSetRenderTargets(1, &win.render_target_view, nil)
		win.device_context->ClearRenderTargetView(win.render_target_view, &clear_color_with_alpha)
		imdx11.RenderDrawData(im.GetDrawData())

		// Update and Render additional Platform Windows
		if .ViewportsEnable in io.ConfigFlags {
			im.UpdatePlatformWindows()
			im.RenderPlatformWindowsDefault()
		}

		// Present
		hr = win.swap_chain->Present(1, {}) // Present with vsync
		//hr := win.swap_chain->Present(0, {}) // Present without vsync
        free_all(context.temp_allocator)
		if hr < 0 && hr != dxgi.STATUS_OCCLUDED {
			log.errorf("Present failed: HRESULT 0x%08X", u32(hr))
		}
		win.swap_chain_occluded = (hr == dxgi.STATUS_OCCLUDED)
	}

	delete(frame_bytes)

	// Finalize any still-active recording/stream before releasing the encoder.
	if output.recording {
		log.info("signalling recording stop on exit")
		mp4.mp4_sink_signal_stop(output.mp4_sink)
		output.finalizing_sink = output.mp4_sink
		output.mp4_sink = nil
		output.recording = false
	}
	if output.streaming {
		log.info("closing stream on exit")
		rtmp.rtmp_stream_close(output.rtmp_stream)
		output.streaming = false
	}

	// Wait for the finalizing sink with a 10s timeout.
	if output.finalizing_sink != nil {
		EXIT_TIMEOUT_MS :: 10_000
		start_tick := time.tick_now()
		for {
			if mp4.mp4_sink_is_stopped(output.finalizing_sink) {
				mp4.mp4_sink_reap(output.finalizing_sink)
				output.finalizing_sink = nil
				break
			}
			if time.duration_milliseconds(time.tick_since(start_tick)) >= EXIT_TIMEOUT_MS {
				log.warn("mp4 sink finalize timed out after 10s, abandoning — skipping encoder_release")
				break
			}
			win32.Sleep(50)
		}
		if output.finalizing_sink != nil {
			// Timed out with the feeder thread still running -- let process exit tear it down.
			return
		}
	}

	if output.enc != nil {
		encode.encoder_release()
		output.enc = nil
	}

	// Persist on a clean shutdown only.
	if paths.shows != "" {
		log.info("save on exit")
		show.save_show(paths.shows, &show_cfg)
	}
}

// Starts, restarts or stops the remote server to match cfg. Safe to call with
// the server already running: it is stopped first.
@(private="file")
start_remote :: proc(
	server:  ^remote.Server,
	running: ^bool,
	bridge:  ^app.Remote_Bridge,
	cfg:     ^config.Remote_Config,
	queue:   ^action.Envelope_Queue,
) {
	if running^ {
		remote.server_stop(server)
		running^ = false
	}
	app.bridge_set_server(bridge, nil)

	if !cfg.enabled {
		log.info("remote control is disabled in the app settings")
		return
	}

	server^ = remote.server_init(remote.Server_Config{
		port            = u16(cfg.port),
		allowed_origins = cfg.allowed_origins,
		server_name     = REMOTE_SERVER_NAME,
	}, queue)

	running^ = remote.server_start(server)
	if running^ {
		app.bridge_set_server(bridge, server)
		log.infof("remote control listening on ws://127.0.0.1:%v/", cfg.port)
	} else {
		log.errorf("remote control could not listen on port %v (already in use?); continuing without it", cfg.port)
	}
}

// Shown in the settings modal's Remote tab.
@(private="file")
remote_status_line :: proc(cfg: ^config.Remote_Config, running: bool) -> string {
	switch {
	case !cfg.enabled: return "Not running."
	case running:      return fmt.tprintf("Listening on ws://127.0.0.1:%v/", cfg.port)
	}
	return fmt.tprintf("Port %v is unavailable -- another app may be using it.", cfg.port)
}
