# cooked's core shell integration for fish: OSC 133 semantic prompts and OSC 7
# directory reporting.
#
# Source it from ~/.config/fish/config.fish:
#
#     test "$TERM_PROGRAM" = cooked; and source /path/to/cooked.fish
#
# Written but unverified -- cooked has never been run against a real fish, which is
# why it is not injected and why the guard is yours to place. See docs/ROADMAP.md.
# The feature list still reaches it: COOKED_SHELL_INTEGRATION_FEATURES is exported to every
# child whether or not anything was injected into it.
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

    if __cooked_want marks
        function __cooked_preexec --on-event fish_preexec
            printf '\033]133;C\007'
        end
    end

    if __cooked_want marks; or __cooked_want cwd
        # One hook, each line gated on its own feature: directory reporting is not
        # part of the marks and outlives them being turned off.
        function __cooked_postexec --on-event fish_postexec
            set -l last_status $status
            __cooked_want marks; and printf '\033]133;D;%s\007' $last_status
            __cooked_want cwd; and printf '\033]7;file://%s%s\007' (hostname) "$PWD"
        end
    end

    # Wrap the user's prompt so the marks bracket it without disturbing its width.
    # Unlike bash and zsh this needs no re-append: fish calls fish_prompt afresh each
    # time, so wrapping the function covers every rebuild by construction.
    #
    # `A' and `B' are gated separately, because `B' is the one mark that changes who
    # owns the keyboard and is a feature of its own.
    #
    # Computed into a variable first: an `if' condition ends at the newline, so a
    # three-clause test would have to be one very long line to be valid at all.
    set -l __cooked_mark_prompt 0
    if __cooked_want marks; or __cooked_want input-mark
        set __cooked_mark_prompt 1
    end

    if test $__cooked_mark_prompt -eq 1; and functions -q fish_prompt; and not functions -q __cooked_inner_prompt
        functions --copy fish_prompt __cooked_inner_prompt

        function fish_prompt
            __cooked_want marks; and printf '\033]133;A\007'
            __cooked_inner_prompt
            __cooked_want input-mark; and printf '\033]133;B\007'
        end
    end
end
