# cooked's core shell integration for fish: OSC 133 semantic prompts and OSC 7
# directory reporting.
#
# Source it from ~/.config/fish/config.fish:
#
#     test "$TERM_PROGRAM" = cooked; and source /path/to/cooked.fish
#
# On fish 4.0 and later most of this stands down, and that is the finding rather than
# a defect: fish marks its own prompts (OSC 133, with kitty's `click_events=1' and
# `cmdline_url='), reports its own directory (OSC 7) and sets its own title (OSC 0),
# all unconditionally, since 4.0.0, and by 4.8 that set is complete -- `B' included.  A
# fish that ran both would emit every mark twice, which cooked survives (see the
# duplicate-mark rules in docs/FEATURES.md) but which is not the same as being right.
# So on such a fish this file stands itself down and gets out of the way; it stays for
# fish 3.x, and for a 4.x running `no-mark-prompt', which is fish's own way of saying
# the marks are somebody else's job.
#
# It is not injected: cooked generates a startup file for zsh and bash and fish needs
# none, so the guard is yours to place.  The feature list still reaches it --
# COOKED_SHELL_INTEGRATION_FEATURES is exported to every child whether or not
# anything was injected into it.
#
# Wrapped in a conditional rather than guarded by an early `exit': in a sourced file
# `exit' means "stop reading this file" only from fish 3.4 onwards, and means "quit
# the shell" before that. A block needs no version floor.

if status is-interactive; and test "$TERM_PROGRAM" = cooked; and not set -q COOKED_INTEGRATION_LOADED
    set -g COOKED_INTEGRATION_LOADED 1

    # The feature list, taken verbatim from the environment so that every shell
    # agrees about what is on. Unset means cooked did not start this one -- an ssh
    # that does not forward the variable, a container -- and the fallback is the
    # same default the Emacs option carries.
    #
    # Read once, here, rather than at each use: config.fish has already run by this
    # point, so it has had its chance to append ` no-marks' and be heard. fish needs
    # no deferred init to arrange that, because sourcing is the last word rather
    # than the first -- there is no hook ordering to lose.
    if set -q COOKED_SHELL_INTEGRATION_FEATURES
        set -g __cooked_features $COOKED_SHELL_INTEGRATION_FEATURES
    else
        set -g __cooked_features "marks input-mark cwd announce completion title"
    end

    # A feature is on if it is named and not un-named; subtraction wins, so an rc
    # appending ` no-marks' is always the last word.
    function __cooked_want --argument-names feature
        string match -q -- "* no-$feature *" " $__cooked_features "; and return 1
        string match -q -- "* $feature *" " $__cooked_features "
    end

    # And fish gets the last word after that.  From 4.0.0 it emits the marks and OSC 7
    # itself, so cooked's half is not merely redundant but a second emitter bracketing
    # the same prompt -- exactly what the `no-NAME' form exists to prevent.  Standing
    # down through that form rather than through a branch of its own is the point: one
    # mechanism decides what is on, and `__cooked_want' goes on being the only thing
    # that answers.
    #
    # In two steps, because fish's own switch does not cover the same ground we do.
    # OSC 7 and the title are unconditional from 4.0.0 and have no switch at all -- a
    # fish under `--features=no-mark-prompt' still reports its directory and still writes
    # its title -- so `cwd' and `title' stand down for any fish 4 whatever else is set.
    #
    # The marks do have a switch, `no-mark-prompt', fish's escape hatch for a terminal
    # that cannot parse the sequences, and it covers the whole set: a 4.8 with marks on
    # emits `A;click_events=1', `B', `C;cmdline_url=' and `D;<status>', which is
    # everything this file has to offer including the `B' that hands Emacs the keyboard.
    # So `input-mark' stands down with the rest rather than apart from it -- the earlier
    # reading, that fish emitted no `B' and ours had to stay, was true of 4.0 and is not
    # true now, and the cost of being wrong about it is two `B' marks bracketing one
    # prompt.  A fish told to be quiet about its marks leaves the whole job to us.
    #
    # `status features' rather than `$fish_features', and the difference is the whole
    # correctness of this.  `$fish_features' is the *request*: it is empty under
    # `fish --features=no-mark-prompt', and holds an unsplit `a,b' string under the
    # comma form, so a `contains' against it misses two of the three documented ways to
    # set the flag.  Missing it is the dangerous direction -- fish's marks off and ours
    # off too is a session with no marks at all.  `status features' reports the state
    # fish actually resolved.
    #
    # The version test is spelled with `string match' because `string split --fields'
    # is fish 3.2 and this file still means to work on 3.x, where the answer is simply
    # that fish marks nothing and everything below stays on.
    if test (string match -r '^[0-9]+' -- $version) -ge 4
        set -g __cooked_features "$__cooked_features no-cwd no-title"
        if not status features | string match -qr '^mark-prompt\s+off'
            set -g __cooked_features "$__cooked_features no-marks no-input-mark"
        end
    end

    #
    # Which marks have been written, so that `close the last command' and `there was no
    # last command' are not spelled the same way.  0 is the first prompt of the session,
    # which has nothing behind it to close; 1 is a `C' still open and owed a `D' with a
    # status; 2 is a prompt that was marked but ran no command -- an empty return, or a
    # cancelled line -- and is owed a bare `D' carrying no status, because there is no
    # status to carry.  zsh keeps the same three states for the same reason.
    #
    set -g __cooked_state 0

    #
    # Percent-encoding, for OSC 7 and for the command line on the `C' mark.  Both are
    # URIs on the wire and Emacs decodes them as URIs, so a path that is not encoded here
    # does not merely look wrong at the far end -- it decodes to a *different* path, and
    # `cd /tmp/100%20cake' becomes a directory that does not exist.
    #
    # fish is the one shell of the three that needs no loop for this: `string escape
    # --style=url' leaves exactly RFC 3986's unreserved set alone, `/' included, which is
    # the rule the bash and zsh halves of cooked spell out by hand.
    #
    if __cooked_want marks
        function __cooked_preexec --on-event fish_preexec
            # `cmdline_url=' rather than kitty's `cmdline=', which is `printf %q' output
            # and so is quoted in a way only that shell can undo.  fish's own 4.x marks
            # send `cmdline_url=' too, which is where the spelling comes from.
            if test -n "$argv[1]"
                printf '\033]133;C;cmdline_url=%s\007' (string escape --style=url -- "$argv[1]")
            else
                printf '\033]133;C\007'
            end
            set -g __cooked_state 1
        end
    end

    if __cooked_want marks
        function __cooked_postexec --on-event fish_postexec
            set -l last_status $status
            printf '\033]133;D;%s\007' $last_status
            set -g __cooked_state 2
        end

        # The safety net: whatever reaches a prompt with a `C' still open closes it here,
        # with a bare `D' because there is no status to give it.  A command interrupted in
        # a way that skips `fish_postexec' is the case that needs it, and `fish_cancel'
        # (Ctrl-C on a line being typed) and `fish_posterror' (a syntax error) are hooked
        # beside `fish_prompt' so that the net is in place even where fish reaches the next
        # prompt by a route that does not redraw.  Ordinarily this fires and does nothing,
        # because `fish_postexec' has already closed the command and set the state -- which
        # is the point.  kitty's fish integration carries the same handler on the same
        # three events; the old version of this file carried none of it, and a command that
        # never got its `D' left a record open until some later command landed inside it.
        function __cooked_close_open --on-event fish_prompt --on-event fish_cancel --on-event fish_posterror
            test "$__cooked_state" -eq 1; and printf '\033]133;D\007'
            set -g __cooked_state 2
        end
    end

    # Reported only when it changed, and never by forking.  The old version of this ran
    # `(hostname)' -- a process -- at every single prompt; fish has carried the answer in
    # `$hostname' all along, which is what kitty's fish integration reads.
    set -g __cooked_last_cwd ""

    if __cooked_want cwd
        function __cooked_report_cwd --on-variable PWD --on-event fish_prompt
            test "$PWD" = "$__cooked_last_cwd"; and return
            set -g __cooked_last_cwd "$PWD"
            printf '\033]7;file://%s%s\007' $hostname (string escape --style=url -- "$PWD")
        end
    end

    if __cooked_want title
        function __cooked_title_preexec --on-event fish_preexec
            printf '\033]2;%s\007' (string replace -ar '[[:cntrl:]]' '' -- "$argv[1]")
        end
        function __cooked_title_prompt --on-event fish_prompt
            printf '\033]2;%s\007' (prompt_pwd)
        end
    end

    #
    # The prompt marks, which have to travel inside `fish_prompt' itself: the
    # `fish_prompt' event fires *before* the function is called, so it is a place to put
    # the opening mark and no place at all to put `B', which must follow the prompt text.
    #
    # So the function is wrapped -- but re-wrapped at every prompt rather than once at
    # startup, which is the whole difference from what this file used to do.  A single
    # wrap at source time is lost the moment anything redefines `fish_prompt', and
    # `fish_config' does exactly that when you change theme, as does any config.fish
    # that defines its prompt after sourcing this.  Checking each time costs one
    # `functions' call per prompt and cannot be got out of step.  It is the same
    # strategy the bash and zsh halves use on PS1, for the same reason.
    #
    # The test is for our own inner function's name inside the current body, which is a
    # thing only our wrapper contains -- so a wrapper cannot wrap itself, which would
    # recurse until fish gave up.
    #
    # The opening mark is a bare `A', which is the same spelling fish 4 sends when it
    # marks its own prompts -- so there is one spelling on the wire whichever of the two
    # is doing the marking.  See the same note in cooked.zsh for why the proposal's `P'
    # is not sent instead.
    #
    function __cooked_wrap_prompt --on-event fish_prompt
        functions -q fish_prompt; or return
        functions fish_prompt | string match -q '*__cooked_inner_prompt*'; and return

        functions -q __cooked_inner_prompt; and functions --erase __cooked_inner_prompt
        functions --copy fish_prompt __cooked_inner_prompt

        function fish_prompt
            __cooked_want marks; and printf '\033]133;A\007'
            __cooked_inner_prompt
            __cooked_want input-mark; and printf '\033]133;B\007'
        end
    end

    # fish redraws the prompt through `fish_prompt', so the wrapper covers every repaint
    # by construction -- there is no equivalent of zsh's `reset-prompt' losing the mark.
    # It does need installing before the first prompt rather than at it, though, because
    # the `fish_prompt' event that would install it fires too late to affect the prompt
    # that emitted it.
    #
    # Skipped entirely when neither half of the prompt marks is wanted, which is a fish 4
    # doing its own marking: wrapping a function to print nothing is still wrapping it,
    # and `functions fish_prompt' would show the user our wrapper for no reason at all.
    if __cooked_want marks; or __cooked_want input-mark
        __cooked_wrap_prompt
    else
        functions --erase __cooked_wrap_prompt
    end
    __cooked_want cwd; and __cooked_report_cwd
    set -g __cooked_state 2
end
