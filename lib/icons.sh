#!/usr/bin/env bash
# Centralized Nerd Font glyph table. Keeping glyphs here makes future font migrations easy.

# Role: Initialize semantic icons, honoring --no-icons client mode.
ka_icons_init() {
    local enabled=${KA_ICONS_ENABLED:-1}
    if [[ $enabled == 1 ]]; then
        KA_I_AI='󰚩'
        KA_I_TERM=''
        KA_I_DIR='󰉋'
        KA_I_SESSION='󰘬'
        KA_I_TIMER='󰔟'
        KA_I_MESSAGE='󰍩'
        KA_I_ENTER='󰌑'
        KA_I_SECONDARY='󰑓'
        KA_I_NOTIFY='󰂚'
        KA_I_ACTIVE='󰐊'
        KA_I_PAUSED='󰏤'
        KA_I_AVAILABLE='󰄬'
        KA_I_WARN='󰀪'
        KA_I_UNAVAILABLE='󰅖'
        KA_I_LOG='󰋚'
        KA_I_CONFIG='󰒓'
        KA_I_DELETE='󰆴'
        KA_I_SERVICE='󰒋'
    else
        KA_I_AI=''
        KA_I_TERM=''
        KA_I_DIR=''
        KA_I_SESSION=''
        KA_I_TIMER=''
        KA_I_MESSAGE=''
        KA_I_ENTER=''
        KA_I_SECONDARY=''
        KA_I_NOTIFY=''
        KA_I_ACTIVE=''
        KA_I_PAUSED=''
        KA_I_AVAILABLE=''
        KA_I_WARN=''
        KA_I_UNAVAILABLE=''
        KA_I_LOG=''
        KA_I_CONFIG=''
        KA_I_DELETE=''
        KA_I_SERVICE=''
    fi
}

# Role: Prefix text with an icon only when icon mode is enabled.
ka_icon_label() {
    ka_icon_label_set "$@"
    printf '%s' "$REPLY"
}

# Role: Put an optional icon followed by text in REPLY, or the text alone without one.
ka_icon_label_set() {
    local icon=${1-} text=${2-}
    if [[ -n $icon ]]; then
        REPLY="$icon $text"
    else
        REPLY=$text
    fi
}
