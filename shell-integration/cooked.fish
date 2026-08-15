# OSC 133 semantic prompts for fish, plus OSC 7 directory reporting.
# Source from ~/.config/fish/config.fish.
#
# Wrapped in a conditional rather than guarded by an early `exit': in a sourced file
# `exit' means "stop reading this file" only from fish 3.4 onwards, and means "quit
# the shell" before that. A block needs no version floor.

if status is-interactive; and not set -q COOKED_INTEGRATION_LOADED
    set -g COOKED_INTEGRATION_LOADED 1

    function __cooked_preexec --on-event fish_preexec
        printf '\033]133;C\007'
    end

    function __cooked_postexec --on-event fish_postexec
        printf '\033]133;D;%s\007' $status
        printf '\033]7;file://%s%s\007' (hostname) "$PWD"
    end

    # Wrap the user's prompt so the marks bracket it without disturbing its width.
    # Unlike bash and zsh this needs no re-append: fish calls fish_prompt afresh each
    # time, so wrapping the function covers every rebuild by construction.
    if functions -q fish_prompt; and not functions -q __cooked_inner_prompt
        functions --copy fish_prompt __cooked_inner_prompt

        function fish_prompt
            printf '\033]133;A\007'
            __cooked_inner_prompt
            printf '\033]133;B\007'
        end
    end
end
