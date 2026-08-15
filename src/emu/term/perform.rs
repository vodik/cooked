//! The single `Perform` impl, and the two dispatches small enough to live in it.
//!
//! A trait impl cannot be split across files, so the large arms are inherent methods
//! next to the state they touch -- `State::csi` in csi.rs, `State::osc` in osc.rs, the
//! image string handlers in image.rs -- and this forwards to them.

use super::*;

impl Perform for State {
    fn print(&mut self, c: char) {
        let c = if self.modes.dec_graphics {
            dec_graphic(c)
        } else {
            c
        };
        let pen = self.pen;
        let underline = self.underline;
        let link = self.link;
        let width = c.width().unwrap_or(0);
        let screen = self.screen_mut();
        let evicted = screen.write(c, pen);
        // After the write, so it lands on the cell the write actually chose — which a
        // wrap or DECAWM may have moved. Only when there is a colour to record: retiring
        // the *previous* occupant's colour is `Row::set`'s job, so nothing here needs a
        // screen-wide "has anything ever been underlined" latch to guard the call. Such a
        // latch cannot be cleared correctly anyway — one `SGR 58` anywhere in a session
        // would make every subsequent character pay for this call forever.
        // Zero-width characters fold onto the cell to their left and never own one, so
        // they must not move an underline colour either.
        if width > 0 && underline != Color::Default {
            screen.mark_underline(underline, width);
        }
        // The same shape, and only when there is a link open: a cell written outside one
        // has nothing attached, because `Row::set` has already retired whatever the
        // previous occupant carried.
        if width > 0 && link.is_some() {
            screen.mark_link(link, width);
        }
        self.evicted(evicted);
        if width > 0 {
            self.last_print = Some(c);
        }
    }

    fn execute(&mut self, byte: u8) {
        match byte {
            0x07 => self.events.push(Event::Bell),
            0x08 => self.screen_mut().backspace(),
            0x09 => self.screen_mut().tab(1),
            0x0A..=0x0C => {
                self.linefeed();
                // LNM: the child asked for LF to imply CR.
                if self.modes.newline_mode {
                    self.screen_mut().carriage_return();
                }
            }
            0x0D => self.screen_mut().carriage_return(),
            0x0E => self.modes.dec_graphics = true,
            0x0F => self.modes.dec_graphics = false,
            _ => {}
        }
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        match (intermediates.first().copied(), byte) {
            (Some(b'('), b'0') => self.modes.dec_graphics = true,
            (Some(b'('), _) => self.modes.dec_graphics = false,
            (None, b'D') => self.linefeed(),
            (None, b'E') => {
                self.screen_mut().carriage_return();
                self.linefeed();
            }
            (None, b'M') => {
                let pen = self.pen;
                self.screen_mut().reverse_index(pen);
            }
            (None, b'H') => self.screen_mut().set_tab(),
            // DECKPAM/DECKPNM. `rs2` and `is2` both end in `ESC >`, so ignoring these
            // meant a reset left the keypad wherever the last program put it.
            (None, b'=') => self.modes.app_keypad = true,
            (None, b'>') => self.modes.app_keypad = false,
            (None, b'7') => self.save_restore(true),
            (None, b'8') => self.save_restore(false),
            (None, b'c') => {
                // RIS is a soft reset that also clears the screen. The pen is default by
                // the time the erase runs, so this is `bce` with nothing to carry.
                self.soft_reset();
                let evicted = self
                    .screen_mut()
                    .erase_display(Erase::All, Style::default());
                self.evicted(evicted);
                self.cleared_display();
                self.screen_mut().goto(0, 0);
            }
            _ => {}
        }
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        self.csi(params, intermediates, action);
    }

    fn hook(&mut self, _params: &Params, intermediates: &[u8], ignore: bool, action: char) {
        self.dcs_hook(intermediates, ignore, action);
    }

    fn put(&mut self, bytes: &[u8]) {
        self.dcs_put(bytes);
    }

    fn unhook(&mut self) {
        self.dcs_unhook();
    }

    fn apc_dispatch(&mut self, bytes: &[u8]) {
        self.apc(bytes);
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.osc(params, bell_terminated);
    }
}
