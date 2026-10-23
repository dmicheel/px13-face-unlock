//! Face ID-style overlay for Gaze face authentication (sudo, polkit, ...).
//!
//! gazed only sends its progress signals to the client that claimed it (pam_gaze), so this
//! follows the gazed journal instead: "Face auth requested" -> scanning, a failure line ->
//! red shake, "Released daemon" without a failure -> green check.
//!
//! Usage: gaze-overlay [--demo]

use std::cell::RefCell;
use std::f64::consts::PI;
use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::rc::Rc;
use std::time::Duration;

use gtk::prelude::*;
use gtk::{cairo, gio, glib};
use gtk4_layer_shell::{Edge, KeyboardMode, Layer, LayerShell};

// The lock screen and greeter use these; nothing can draw above a session lock anyway,
// and the check mark would only flash up after unlocking.
const IGNORED_SERVICES: &[&str] = &["login", "greetd"];

const SIZE: i32 = 168; // window, logical px
const PANEL: f64 = 136.0; // rounded panel inside it
const MARGIN_BOTTOM: i32 = 96;

type Rgb = (f64, f64, f64);
const WHITE: Rgb = (1.0, 1.0, 1.0);
const GREEN: Rgb = (0.20, 0.78, 0.35);
const RED: Rgb = (1.0, 0.27, 0.23);

const FADE_IN: f64 = 0.15;
const FADE_OUT: f64 = 0.25;
const SUCCESS_HOLD: f64 = 0.9;
const FAIL_HOLD: f64 = 1.3;
const SCAN_TIMEOUT: f64 = 20.0;

const FAILED: &[&str] = &[
    "matched=false",
    "giving up after",
    "liveness check did not pass",
    "all capture threads exited",
    "No matching templates",
];
const ABORTED: &[&str] = &["cancelled", "Laptop lid is closed"];

#[derive(Clone, Copy, PartialEq)]
enum Phase {
    Scan,
    Success,
    Fail,
    Abort,
}

impl Phase {
    /// How long the result stays before fading out; scanning has no end of its own.
    fn hold(self) -> Option<f64> {
        match self {
            Phase::Scan => None,
            Phase::Success => Some(SUCCESS_HOLD),
            Phase::Fail => Some(FAIL_HOLD),
            Phase::Abort => Some(0.0),
        }
    }
}

#[derive(Default)]
struct State {
    phase: Option<Phase>,
    since: f64, // when the current phase started
    shown: f64, // when the overlay appeared
    ticking: bool,
}

#[derive(Clone)]
struct Overlay {
    window: gtk::ApplicationWindow,
    area: gtk::DrawingArea,
    state: Rc<RefCell<State>>,
}

impl Overlay {
    fn new(app: &gtk::Application) -> Self {
        let window = gtk::ApplicationWindow::new(app);
        window.init_layer_shell();
        window.set_namespace(Some("gaze-overlay"));
        window.set_layer(Layer::Overlay);
        window.set_anchor(Edge::Bottom, true);
        window.set_margin(Edge::Bottom, MARGIN_BOTTOM);
        window.set_keyboard_mode(KeyboardMode::None);
        window.set_default_size(SIZE, SIZE);

        let css = gtk::CssProvider::new();
        css.load_from_string("window { background: transparent; }");
        gtk::style_context_add_provider_for_display(
            &WidgetExt::display(&window),
            &css,
            gtk::STYLE_PROVIDER_PRIORITY_APPLICATION,
        );

        let area = gtk::DrawingArea::builder()
            .content_width(SIZE)
            .content_height(SIZE)
            .build();
        window.set_child(Some(&area));
        window.connect_realize(|w| {
            if let Some(surface) = w.surface() {
                surface.set_input_region(Some(&cairo::Region::create()));
            }
        });

        let state = Rc::new(RefCell::new(State::default()));
        let draw_state = state.clone();
        area.set_draw_func(move |_, cr, w, h| draw(&draw_state.borrow(), cr, w as f64, h as f64));

        Overlay { window, area, state }
    }

    fn scan(&self) {
        let mut st = self.state.borrow_mut();
        if st.phase == Some(Phase::Scan) {
            return;
        }
        let t = now();
        if st.phase.is_none() {
            st.shown = t;
        }
        st.phase = Some(Phase::Scan);
        st.since = t;
        let start_ticking = !st.ticking;
        st.ticking = true;
        drop(st);

        self.window.set_visible(true);
        if start_ticking {
            let this = self.clone();
            self.area.add_tick_callback(move |_, _| this.tick());
        }
    }

    fn finish(&self, result: Phase) {
        let mut st = self.state.borrow_mut();
        if st.phase == Some(Phase::Scan) {
            st.phase = Some(result);
            st.since = now();
        }
    }

    fn tick(&self) -> glib::ControlFlow {
        let mut st = self.state.borrow_mut();
        let elapsed = now() - st.since;
        let done = match st.phase {
            None => true,
            Some(phase) => match phase.hold() {
                Some(hold) => elapsed > hold + FADE_OUT,
                None => elapsed > SCAN_TIMEOUT,
            },
        };
        if done {
            st.phase = None;
            st.ticking = false;
            drop(st);
            self.window.set_visible(false);
            return glib::ControlFlow::Break;
        }
        drop(st);
        self.area.queue_draw();
        glib::ControlFlow::Continue
    }
}

fn now() -> f64 {
    glib::monotonic_time() as f64 / 1e6
}

fn ease_out(t: f64) -> f64 {
    1.0 - (1.0 - t.clamp(0.0, 1.0)).powi(3)
}

fn mix(a: Rgb, b: Rgb, t: f64) -> Rgb {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

fn set_color(cr: &cairo::Context, c: Rgb) {
    cr.set_source_rgb(c.0, c.1, c.2);
}

// Drawing. Cairo errors only mean a broken context; nothing useful to do with them.

fn draw(st: &State, cr: &cairo::Context, w: f64, h: f64) {
    let Some(phase) = st.phase else { return };
    let t = now();
    let elapsed = t - st.since;

    let mut alpha = ease_out((t - st.shown) / FADE_IN);
    if let Some(hold) = phase.hold().filter(|&hold| elapsed > hold) {
        alpha *= 1.0 - ((elapsed - hold) / FADE_OUT).min(1.0);
    }
    let scale = 0.88 + 0.12 * ease_out((t - st.shown) / 0.25);
    let shake = if phase == Phase::Fail && elapsed < 0.5 {
        10.0 * (elapsed * 2.0 * PI * 7.0).sin() * (1.0 - elapsed / 0.5)
    } else {
        0.0
    };

    cr.translate(w / 2.0 + shake, h / 2.0);
    cr.scale(scale, scale);
    cr.push_group();

    rounded_rect(cr, -PANEL / 2.0, -PANEL / 2.0, PANEL, PANEL, 34.0);
    cr.set_source_rgba(0.08, 0.08, 0.09, 0.86);
    let _ = cr.fill();

    cr.set_line_cap(cairo::LineCap::Round);
    cr.set_line_join(cairo::LineJoin::Round);
    match phase {
        Phase::Scan => draw_scan(cr, t - st.shown),
        Phase::Success => draw_success(cr, elapsed),
        Phase::Fail => draw_fail(cr, elapsed),
        Phase::Abort => {
            brackets(cr, 40.0, WHITE);
            face(cr, WHITE, 1.0);
        }
    }

    let _ = cr.pop_group_to_source();
    let _ = cr.paint_with_alpha(alpha);
}

fn draw_scan(cr: &cairo::Context, t: f64) {
    let breathe = (1.0 - (t * 2.0 * PI / 1.4).cos()) / 2.0; // 0..1
    brackets(cr, 40.0 - 4.0 * breathe, WHITE);
    face(cr, WHITE, 1.0);

    // scan line sweeping up and down between the brackets
    let y = 34.0 * (t * 2.0 * PI / 1.6).sin();
    let glow = cairo::LinearGradient::new(-34.0, 0.0, 34.0, 0.0);
    for (stop, a) in [(0.0, 0.0), (0.5, 0.95), (1.0, 0.0)] {
        glow.add_color_stop_rgba(stop, WHITE.0, WHITE.1, WHITE.2, a);
    }
    let _ = cr.set_source(&glow);
    cr.set_line_width(2.5);
    cr.move_to(-34.0, y);
    cr.line_to(34.0, y);
    let _ = cr.stroke();
}

fn draw_success(cr: &cairo::Context, t: f64) {
    let k = ease_out(t / 0.3);
    let color = mix(WHITE, GREEN, k);
    brackets(cr, 40.0 - 4.0 * (1.0 - k), color);
    if k < 1.0 {
        cr.push_group();
        face(cr, color, 1.0);
        let _ = cr.pop_group_to_source();
        let _ = cr.paint_with_alpha(1.0 - k);
    }
    checkmark(cr, ease_out((t - 0.1) / 0.3), GREEN);
}

fn draw_fail(cr: &cairo::Context, t: f64) {
    let k = ease_out(t / 0.25);
    let color = mix(WHITE, RED, k);
    brackets(cr, 40.0, color);
    face(cr, color, 1.0 - 1.6 * k);
}

fn rounded_rect(cr: &cairo::Context, x: f64, y: f64, w: f64, h: f64, r: f64) {
    cr.new_sub_path();
    cr.arc(x + w - r, y + r, r, -PI / 2.0, 0.0);
    cr.arc(x + w - r, y + h - r, r, 0.0, PI / 2.0);
    cr.arc(x + r, y + h - r, r, PI / 2.0, PI);
    cr.arc(x + r, y + r, r, PI, 3.0 * PI / 2.0);
    cr.close_path();
}

/// Four rounded corner brackets of a square with the given half size.
fn brackets(cr: &cairo::Context, half: f64, color: Rgb) {
    let (length, r) = (16.0, 9.0);
    set_color(cr, color);
    cr.set_line_width(4.5);
    for (sx, sy) in [(-1.0, -1.0), (1.0, -1.0), (1.0, 1.0), (-1.0, 1.0)] {
        let (cx, cy) = (sx * half, sy * half);
        cr.move_to(cx, cy - sy * length);
        cr.line_to(cx, cy - sy * r);
        cr.curve_to(cx, cy, cx, cy, cx - sx * r, cy);
        cr.line_to(cx - sx * length, cy);
        let _ = cr.stroke();
    }
}

/// Face glyph; smile 1 = smiling, 0 = flat, <0 = frowning.
fn face(cr: &cairo::Context, color: Rgb, smile: f64) {
    set_color(cr, color);
    cr.set_line_width(4.0);
    for x in [-12.0, 12.0] {
        // eyes
        cr.move_to(x, -13.0);
        cr.line_to(x, -6.0);
        let _ = cr.stroke();
    }
    cr.move_to(1.0, -12.0); // nose
    cr.line_to(1.0, 3.0);
    cr.line_to(-3.0, 3.0);
    let _ = cr.stroke();
    cr.move_to(-13.0, 11.0); // mouth
    cr.curve_to(-5.0, 11.0 + 7.0 * smile, 5.0, 11.0 + 7.0 * smile, 13.0, 11.0);
    let _ = cr.stroke();
}

fn checkmark(cr: &cairo::Context, progress: f64, color: Rgb) {
    if progress <= 0.0 {
        return;
    }
    let points = [(-16.0, 1.0), (-5.0, 12.0), (17.0, -12.0)];
    let segments: Vec<_> = points.windows(2).map(|p| (p[0], p[1])).collect();
    let total: f64 = segments.iter().map(|&(a, b)| dist(a, b)).sum();
    let mut remaining = progress * total;

    set_color(cr, color);
    cr.set_line_width(6.0);
    cr.move_to(points[0].0, points[0].1);
    for ((x0, y0), (x1, y1)) in segments {
        let len = dist((x0, y0), (x1, y1));
        let f = (remaining / len).min(1.0);
        cr.line_to(x0 + (x1 - x0) * f, y0 + (y1 - y0) * f);
        remaining -= len;
        if remaining <= 0.0 {
            break;
        }
    }
    let _ = cr.stroke();
}

fn dist(a: (f64, f64), b: (f64, f64)) -> f64 {
    (b.0 - a.0).hypot(b.1 - a.1)
}

// Journal

/// Follows the gazed journal on a thread and drives the overlay from the main loop.
fn watch_journal(overlay: Overlay) {
    let (tx, rx) = async_channel::unbounded::<String>();
    std::thread::spawn(move || {
        loop {
            let child = Command::new("journalctl")
                .args(["-u", "gazed", "-f", "-n", "0", "-o", "cat"])
                .stdout(Stdio::piped())
                .spawn();
            if let Ok(mut child) = child {
                let stdout = BufReader::new(child.stdout.take().expect("piped stdout"));
                for line in stdout.split(b'\n') {
                    let Ok(line) = line else { break };
                    let line = String::from_utf8_lossy(&line).into_owned();
                    if tx.send_blocking(line).is_err() {
                        return;
                    }
                }
                let _ = child.wait();
            }
            // journalctl exited or could not start; try again
            std::thread::sleep(Duration::from_secs(2));
        }
    });

    glib::spawn_future_local(async move {
        let user = glib::user_name().to_string_lossy().into_owned();
        let mut claimed_by: Option<String> = None;
        while let Ok(line) = rx.recv().await {
            let line = strip_ansi(&line);
            if line.contains("Claimed daemon") {
                claimed_by = field(&line, "username=", ' ').map(str::to_owned);
            } else if line.contains("Face auth requested") {
                let service = field(&line, "service=\"", '"');
                if claimed_by.as_deref() == Some(user.as_str())
                    && service.is_some_and(|s| !IGNORED_SERVICES.contains(&s))
                {
                    overlay.scan();
                }
            } else if FAILED.iter().any(|s| line.contains(s)) {
                overlay.finish(Phase::Fail);
            } else if ABORTED.iter().any(|s| line.contains(s)) {
                overlay.finish(Phase::Abort);
            } else if line.contains("Released daemon") {
                overlay.finish(Phase::Success);
            }
        }
    });
}

/// The value after `key`, up to `end` or the end of the line.
fn field<'a>(line: &'a str, key: &str, end: char) -> Option<&'a str> {
    let rest = &line[line.find(key)? + key.len()..];
    rest.split(end).next()
}

/// gazed logs with colors even into the journal.
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\x1b' {
            chars.by_ref().find(|c| c.is_ascii_alphabetic());
        } else {
            out.push(c);
        }
    }
    out
}

fn demo(overlay: &Overlay) {
    let steps = [
        (0.0, Phase::Scan),
        (1.8, Phase::Success),
        (3.5, Phase::Scan),
        (5.5, Phase::Fail),
    ];
    for (delay, phase) in steps {
        let overlay = overlay.clone();
        glib::timeout_add_local_once(Duration::from_secs_f64(delay), move || match phase {
            Phase::Scan => overlay.scan(),
            result => overlay.finish(result),
        });
    }
}

fn main() -> glib::ExitCode {
    let demo_mode = std::env::args().any(|a| a == "--demo");
    let app = gtk::Application::builder()
        .application_id("io.github.dmicheel.GazeOverlay")
        .flags(gio::ApplicationFlags::NON_UNIQUE)
        .build();

    app.connect_activate(move |app| {
        let overlay = Overlay::new(app);
        std::mem::forget(app.hold());
        if demo_mode {
            demo(&overlay);
            glib::timeout_add_seconds_local(8, move || {
                demo(&overlay);
                glib::ControlFlow::Continue
            });
        } else {
            watch_journal(overlay);
        }
    });
    app.run_with_args(&["gaze-overlay"])
}
