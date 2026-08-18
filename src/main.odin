package main

import "base:intrinsics"

import "core:time"
import "core:os"
import "core:strings"
import "core:math"
import "core:flags"
import "core:container/queue"
import "core:unicode/utf8"
import "core:prof/spall"

import k2 "../karl2d"


// input state
is_mouse_down:       bool
was_mouse_down:      bool
clicked:             bool
double_clicked:      bool
clicked_t:           time.Tick
mouse_up_now:        bool
is_hovering:         bool

alt_down:            bool
shift_down:          bool
ctrl_down:           bool
super_down:          bool

last_mouse_pos:      Vec2
mouse_pos:           Vec2
clicked_pos:         Vec2
scroll_val_y:        f64

cam := Camera{0, 0, 0, 1, 1}

// selection state
clicked_on_rect := false

// tooltip-state
rect_tooltip_rect := empty_event
rect_tooltip_pos := Vec2{}
rendered_rect_tooltip := false

did_pan := false

stat_sort_type:       SortState
stat_sort_descending: bool = true
resort_stats:         bool

// drawing state
colormode      := ColorMode.Dark

// font data
dpr:          f64 = 1
p_height:     f64 = 14
h1_height:    f64 = 18
h2_height:    f64 = 16
em:           f64 = p_height
p_font_size:  f64 = p_height
h1_font_size: f64 = h1_height
h2_font_size: f64 = h2_height
ch_width:     f64 = 0
thread_gap:   f64 = 8

build_hash := 0
enable_debug := false
fps_history: queue.Queue(f64)


fullscreen := false

t:                f64
multiselect_t:    f64
greyanim_t:       f32
greymotion:       f32
frame_count:      int
last_frame_count: int
was_sleeping:     bool
awake:            bool
random_seed:      u64

// loading / trace state
loader: Loader

ThreadSampleRunState :: struct {
	trace:        ^Trace,
	ui_state:     ^UIState,
	program_name: string,
	program_path: string,
	program_args: string,
}

threaded_sample_start_cleanup :: proc(data: rawptr) {
	if data != nil {
		free((^ThreadSampleRunState)(data))
	}
}

threaded_sample_start :: proc(loader: ^Loader, data: rawptr) {
	using state := (^ThreadSampleRunState)(data)

	defer free(state)

	// TODO replace me with something that respects quote-escapes
	args := []string{}
	if len(program_args) > 0 {
		args = strings.split(program_args, " ")
	}

	sample_child(trace, program_name, program_path, args)

	pool_wait(&loader.pool)
	free_trace_temps(trace)

	ui_state.loading_config = false
	ui_state.post_loading = true
}

start_sampling :: proc(loader: ^Loader, trace: ^Trace, ui_state: ^UIState, program_name: string, program_path: string, program_args: string) -> bool {
	if ui_state.loading_config || program_name == "" {
		return false
	}

	free_trace(trace)
	init_trace(trace)
	trace.load_kickoff = time.tick_now()
	ui_state.loading_config = true
	ui_state.post_loading = false
	ui_state.ui_mode = .SampleRunning

	state := new(ThreadSampleRunState)
	state^ = ThreadSampleRunState{
		trace = trace,
		ui_state = ui_state,
		program_name = program_name,
		program_path = program_path,
		program_args = program_args,
	}

	loader_set_task(loader, Loader_Task{do_work = threaded_sample_start, args = state, cleanup = threaded_sample_start_cleanup})
	return true
}

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

SELF_TRACE    :: #config(SELF_TRACE, false)
GOOD_BOY_MODE :: #config(GOOD_BOY_MODE, false)
opt: Cmd_Options

when SELF_TRACE {
	@(instrumentation_enter)
	spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
}

Cmd_Options :: struct {
	file:          string `args:"pos=0"                      usage:"Trace file to load"`,
	terminal_mode: bool   `args:"hidden, name=terminal-mode" usage:"Loads traces headlessly"`,
	full_speed:    bool   `args:"hidden, name=full-speed"    usage:"Disables power-limiter to max out framerate"`,
	sample_exe:    string `args:"name=sample-exe"            usage:"Sets sample exe path"`,
	sample_path:   string `args:"name=sample-path"           usage:"Sets sample exe target path"`,
	sample_args:   string `args:"name=sample-args"           usage:"Sets sample args"`,
	exe_path:      string `args:"name=exe-path"              usage:"Overrides exe path for trace files"`,
	pdb_path:      string `args:"name=pdb-path"              usage:"Overrides pdb path for trace files"`,
}

// shutdown_runtime owns the application teardown order.  Loader workers and
// trace storage must be gone before the frontend releases fonts and Karl2D.
// Keeping this in one path also makes terminal and GUI early exits equivalent.
shutdown_runtime :: proc(loader: ^Loader, trace: ^Trace, gfx: ^GFX_Context) {
	if loader != nil {
		loader_destroy(loader)
	}

	if trace != nil {
		free_trace(trace)
		free(trace)
	}

	if gfx != nil {
		shutdown_context(gfx)
	}
}

main :: proc() {
	when SELF_TRACE {
		current_time := time.time_to_unix(time.now())
		trace_name := fmt.tprintf("spall_timing_%d.spall", current_time)
		spall_ctx = spall.context_create(trace_name)
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
		spall_buffer = spall.buffer_create(buffer_backing)
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	flags.parse_or_exit(&opt, os.args, .Unix)

	ui_state := UIState{
		post_loading = true,
		textboxes = make(map[TextboxKind]TextboxState),
	}

	ui_state.textboxes[.ProgramInput] = init_textbox_state()
	ui_state.textboxes[.CmdArgsInput] = init_textbox_state()
	ui_state.textboxes[.PathInput]    = init_textbox_state()
	first  := &ui_state.textboxes[.ProgramInput]
	second := &ui_state.textboxes[.PathInput]
	third  := &ui_state.textboxes[.CmdArgsInput]
	first.next = second
	first.prev = third
	second.next = third
	second.prev = first
	third.next = first
	third.prev = second

	start_trace := ""
	open_mode := UIMode.TraceView
	// If user set a file on the cmdline
	if opt.file != "" {
		start_trace = strings.clone(opt.file)
	} else {

		// Does the platform support sampling?
		if supports_sampling() {
			open_mode = .MainMenu

			if opt.sample_exe != "" {
				strings.write_string(&first.b, opt.sample_exe)
				first.cursor = len(opt.sample_exe)
			}
			if opt.sample_path != "" {
				strings.write_string(&second.b, opt.sample_path)
				second.cursor = len(opt.sample_path)
			}
			if opt.sample_args != "" {
				strings.write_string(&third.b, opt.sample_args)
				third.cursor = len(opt.sample_args)
			}
		}
	}

	clicked_t = time.tick_now()
	ui_state.ui_mode = open_mode

	thread_count := 1//max(os.processor_core_count() - 1, 1)
	loader_init(&loader, thread_count)
	trace := new(Trace)
	init_trace(trace)

	if opt.terminal_mode {
		// start_trace is an owned clone. load_trace transfers it to the worker
		// on success and releases it itself when the request is rejected.
		if !load_trace(&loader, trace, &ui_state, start_trace) {
			shutdown_runtime(&loader, trace, nil)
			return
		}
		shutdown_runtime(&loader, trace, nil)
		return
	}
	// start_trace ownership transfers to ThreadFileLoadState on submission.
	load_trace(&loader, trace, &ui_state, start_trace)

	set_color_mode(false, true)

	gfx: GFX_Context
	width, height: f64
	gfx, dpr, width, height = create_context("spall", 1280, 720)

	ch_width = measure_text("a", .PSize, .MonoFont)

	next_line(&ui_state.line_height, em)
	ui_state.info_pane_height = (ui_state.line_height * 12)

	start_tick := time.tick_now()
	last_tick: time.Tick
	awake := true
	was_sleeping := false
	main_loop: for {
		defer {
			clicked                  = false
			double_clicked           = false
			is_hovering              = false
			was_mouse_down           = false
			mouse_up_now             = false
			ui_state.render_one_more = false
			frame_count             += 1
			free_all(context.temp_allocator)
		}

		cur_tick := time.tick_now()
		duration := time.tick_since(start_tick)
		t = time.duration_milliseconds(duration)

		dt := time.duration_seconds(time.tick_diff(last_tick, cur_tick))
		last_tick = cur_tick

		if queue.len(fps_history) > 100 do queue.pop_front(&fps_history)
		queue.push_back(&fps_history, 1 / dt)

		// prevent dt from going *too* nuts if we've just woken up
		if was_sleeping {
			dt = min(0.016, dt)
			was_sleeping = false
		}

		should_toggle_fullscreen := false

		// if any of the textboxes are in focus, enable keyboard capture
		capture_text:    bool
		selected_box_id: TextboxKind
		selected_box:    ^TextboxState
		for id, box in ui_state.textboxes {
			if box.focus {
				capture_text = true
				selected_box_id = id
				break
			}
		}

		if capture_text {
			selected_box = &ui_state.textboxes[selected_box_id]
		}

		dpr = gfx.window_scale

		events := get_events(&gfx, block=!awake) or_break main_loop
		event_loop: for event in events {

			if !awake {
				was_sleeping = true
				awake        = true
			}

			#partial switch ev in event {
			case k2.Event_Close_Window_Requested:
				break main_loop

			case k2.Event_Mouse_Move:
				p := karl2d_coords_physical_to_logical(karl2d_current_coords(&gfx), Vec2(ev.position))
				mouse_moved(p.x, p.y)

			case k2.Event_Mouse_Button_Went_Up:
				if ev.button == .Left {
					p := karl2d_coords_physical_to_logical(karl2d_current_coords(&gfx), Vec2(k2.get_mouse_position()))
					mouse_up(p.x, p.y)
				}

			case k2.Event_Mouse_Button_Went_Down:
				if ev.button == .Left {
					p := karl2d_coords_physical_to_logical(karl2d_current_coords(&gfx), Vec2(k2.get_mouse_position()))
					mouse_down(p.x, p.y)
				}

			case k2.Event_Mouse_Wheel:
				mouse_scroll(f64(ev.delta))

			case k2.Event_Key_Went_Down,
				 k2.Event_Key_Repeat:

				key: k2.Keyboard_Key
				#partial switch ev in event {
				case k2.Event_Key_Went_Down: key = ev.key
				case k2.Event_Key_Repeat:    key = ev.key
				}

				#partial switch key {
				case .Left_Shift:    shift_down = true
				case .Right_Shift:   shift_down = true
				case .Left_Control:  ctrl_down  = true
				case .Right_Control: ctrl_down  = true
				case .Left_Alt:      alt_down   = true
				case .Right_Alt:     alt_down   = true
				case .Left_Super:    super_down = true
				case .Right_Super:   super_down = true

				case .F11: should_toggle_fullscreen = true
				case .Enter:
					if alt_down {
						should_toggle_fullscreen = true
					}
				case .Backspace:
					if capture_text {
						new_cursor := step_left_rune(selected_box.b.buf[:], selected_box.cursor)
						remove_range(&selected_box.b.buf, new_cursor, selected_box.cursor)
						selected_box.cursor = new_cursor
					}
				case .Tab:
					if capture_text {
						selected_box.focus = false
						if shift_down {
							selected_box = selected_box.prev
						} else {
							selected_box = selected_box.next
						}
						selected_box.focus = true
					}
				case .Left:
					if capture_text {
						selected_box.cursor = step_left_rune(selected_box.b.buf[:], selected_box.cursor)
					}
				case .Right:
					if capture_text {
						selected_box.cursor = step_right_rune(selected_box.b.buf[:], selected_box.cursor)
					}
				case .Up:
					if capture_text {
						selected_box.cursor = 0
					}
				case .Down:
					if capture_text {
						selected_box.cursor = len(selected_box.b.buf)
					}
				case .V:
					if capture_text && (ctrl_down || super_down) {
						path := get_clipboard()
						defer delete(path)
						strings.builder_reset(&selected_box.b)
						strings.write_string(&selected_box.b, path)
						selected_box.cursor = len(selected_box.b.buf)
					}
				case .R:
					if !capture_text && (ctrl_down || super_down) {
						load_trace(&loader, trace, &ui_state, strings.clone(trace.file_name))
					}
				}

			case k2.Event_Key_Went_Up:
				#partial switch ev.key {
				case .Left_Shift:    shift_down = false
				case .Right_Shift:   shift_down = false
				case .Left_Control:  ctrl_down  = false
				case .Right_Control: ctrl_down  = false
				case .Left_Alt:      alt_down   = false
				case .Right_Alt:     alt_down   = false
				case .Left_Super:    super_down = false
				case .Right_Super:   super_down = false
				}

			case k2.Event_Screen_Resize:
				width  = f64(ev.width)
				height = f64(ev.height)
				karl2d_coords_update_gfx(&gfx, ev.width, ev.height, gfx.window_scale)

			case k2.Event_Window_Scale_Changed:
				width  = f64(ev.screen_width)
				height = f64(ev.screen_height)
				karl2d_coords_update_gfx(&gfx, ev.screen_width, ev.screen_height, f64(ev.scale))

			// TODO: file drop
            // case .FileDropped:
            //     load_trace(&loader, trace, &ui_state, strings.clone(ev.str))
            //     path, ok := ui_drop_path(ev)
            //     if ok {
            //         // path is owned by this call and consumed by load_trace.
            //     }

            case k2.Event_Typed_Rune:
                if capture_text {
                    cur_str := strings.to_string(selected_box.b)
                    cur_len := utf8.rune_count_in_string(cur_str)

					buf, w := utf8.encode_rune(ev.typed)
					str := string(buf[:w])

                    if selected_box.cursor == cur_len {
                        strings.write_string(&selected_box.b, str)
                        selected_box.cursor += 1
                    } else {
                        inject_at(&selected_box.b.buf, selected_box.cursor, str)
                        selected_box.cursor += 1
                    }
                }
			}
		}

        // Don't draw anything when not awake
        if !awake do continue main_loop

		if should_toggle_fullscreen {
			fullscreen = !fullscreen
			w, h := set_fullscreen(&gfx, fullscreen)
			width = f64(w)
			height = f64(h)
		}

		k2.clear(bg_color2)

		ui_state.height = height / dpr
		ui_state.width  = width / dpr

		header_height   := 3 * em
		spall_x_pad     := 3 * em
		activity_height := 2 * em
		timebar_height  := 3 * em
		rect_height     := em + (0.75 * em)
		top_line_gap    := (em / 1.5)

		topbars_height    := header_height + timebar_height + activity_height
		minigraph_width   := 15 * em
		flamegraph_width  := ui_state.width - (spall_x_pad + minigraph_width)
		flamegraph_height := ui_state.height - topbars_height - ui_state.info_pane_height

		tab_select_height := 2 * em
		filter_pane_width := ui_state.filters_open ? (15 * em) : 0
		stats_pane_x := filter_pane_width

		ui_state.side_pad                  = spall_x_pad
		ui_state.rect_height               = rect_height
		ui_state.topbars_height            = topbars_height
		ui_state.top_line_gap              = top_line_gap
		ui_state.flamegraph_toptext_height = (ui_state.top_line_gap * 2) + (2 * em)
		ui_state.flamegraph_header_height  = ui_state.flamegraph_toptext_height + em

		ui_state.header_rect             = Rect{0, 0, ui_state.width, header_height}
		ui_state.global_timebar_rect     = Rect{0, header_height, ui_state.width, timebar_height}
		ui_state.global_activity_rect    = Rect{spall_x_pad, header_height + timebar_height, flamegraph_width, activity_height}
		ui_state.local_timebar_rect      = Rect{spall_x_pad, header_height + timebar_height + activity_height, flamegraph_width, timebar_height}
		ui_state.minimap_rect            = Rect{ui_state.width - minigraph_width, topbars_height, minigraph_width, flamegraph_height}

		ui_state.info_pane_rect          = Rect{0, ui_state.height - ui_state.info_pane_height, ui_state.width, ui_state.info_pane_height}
		ui_state.tab_rect                = Rect{0, ui_state.info_pane_rect.y, ui_state.width, tab_select_height}

		pane_start_y := ui_state.tab_rect.y + ui_state.tab_rect.h

		info_subpane_height := ui_state.info_pane_height - tab_select_height
		ui_state.filter_pane_rect        = Rect{0, pane_start_y, filter_pane_width, info_subpane_height}
		ui_state.stats_pane_rect         = Rect{stats_pane_x, pane_start_y, ui_state.width - stats_pane_x, info_subpane_height}

		ui_state.full_flamegraph_rect    = Rect{spall_x_pad, topbars_height, flamegraph_width, flamegraph_height}

		ui_state.inner_flamegraph_rect    = ui_state.full_flamegraph_rect
		ui_state.inner_flamegraph_rect.y += ui_state.flamegraph_toptext_height
		ui_state.inner_flamegraph_rect.h -= ui_state.flamegraph_toptext_height

		ui_state.padded_flamegraph_rect    = ui_state.inner_flamegraph_rect
		ui_state.padded_flamegraph_rect.y += em
		ui_state.padded_flamegraph_rect.h -= em

		#partial switch ui_state.ui_mode {
        case .MainMenu:      draw_main_menu(&gfx, trace, &ui_state, dt)
        case .SampleRunning: draw_sample_running(&gfx, trace, &ui_state, dt)
        case .TraceLoading:  draw_trace_loading(&gfx, trace, &ui_state, dt)
        case .TraceView:     draw_trace_view(&gfx, trace, &ui_state,  dt)
		}

		// reset the cursor if we're not over a selectable thing
		if !is_hovering {
			reset_cursor(&gfx)
		}

		// save me my battery, plz
        awake = !should_sleep(&cam, &ui_state)
		if !awake {
			cam.pan.x                       = cam.target_pan_x
			cam.vel.y                       = 0
			cam.current_scale               = cam.target_scale
			ui_state.stats_pane_scroll_vel  = 0
			ui_state.filter_pane_scroll_vel = 0
		}

		k2.present()
	}

	shutdown_runtime(&loader, trace, &gfx)
	queue.destroy(&fps_history)
}

should_sleep :: proc(cam: ^Camera, ui_state: ^UIState) -> bool {

    // TODO: scaling is causing endless sleep
    // if true do return false

	PAN_X_EPSILON  :: 0.01
	PAN_Y_EPSILON  :: 1.0
	SCALE_EPSILON  :: 0.01
	SCROLL_EPSILON :: 0.01

	if opt.full_speed {
		return false
	}

	panning_x := math.abs(cam.pan.x - cam.target_pan_x) > PAN_X_EPSILON
	panning_y := math.abs(cam.vel.y - 0) > PAN_Y_EPSILON
	scaling   := math.abs((cam.current_scale - cam.target_scale) / cam.target_scale) > SCALE_EPSILON
	scrolling := (math.abs(ui_state.filter_pane_scroll_vel) > SCROLL_EPSILON) || (math.abs(ui_state.stats_pane_scroll_vel) > SCROLL_EPSILON)

	return (!ui_state.render_one_more && !panning_x && !panning_y && !scaling && !scrolling)
}
