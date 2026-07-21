#!/usr/bin/env bash
# =============================================================================
# lib/interactive.sh — MoodleKit terminal UI components
# =============================================================================
# Arrow-key menus, checkbox selectors, text input, spinner, progress bar.
# Degrades gracefully in non-interactive (piped/cron) mode.
# =============================================================================

[[ -n "${_MOODLEKIT_INTERACTIVE_LOADED:-}" ]] && return 0
_MOODLEKIT_INTERACTIVE_LOADED=1

# ---------------------------------------------------------------------------
# TTY detection
# ---------------------------------------------------------------------------
is_interactive() {
    [[ -t 0 ]] && [[ -t 1 ]] && [[ "${MOODLEKIT_YES:-0}" != "1" ]]
}

# ---------------------------------------------------------------------------
# Single-select menu (radio buttons)
# Usage: select_one RESULT_VAR "Prompt" option1 option2 ...
# Sets RESULT_VAR to the selected option string
# ---------------------------------------------------------------------------
select_one() {
    local -n _result_ref="$1"; shift
    local prompt="$1"; shift
    local options=("$@")
    local selected=0

    if ! is_interactive; then
        # Non-interactive: return first option
        _result_ref="${options[0]}"
        return 0
    fi

    # Save terminal state
    local old_stty
    old_stty="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon 2>/dev/null || true

    local key
    local num="${#options[@]}"

    _print_radio_menu() {
        # Move cursor up to redraw
        for (( i=0; i<num+2; i++ )); do
            echo -ne "\033[1A\033[2K"
        done
        echo -e "${C_BOLD}${prompt}${C_RESET}"
        echo ""
        for (( i=0; i<num; i++ )); do
            if (( i == selected )); then
                echo -e "  ${C_BOLD_CYAN}●${C_RESET}  ${C_BOLD}${options[$i]}${C_RESET}"
            else
                echo -e "  ${C_DIM}○${C_RESET}  ${C_DIM}${options[$i]}${C_RESET}"
            fi
        done
    }

    # Initial draw
    echo -e "${C_BOLD}${prompt}${C_RESET}"
    echo ""
    for (( i=0; i<num; i++ )); do
        if (( i == 0 )); then
            echo -e "  ${C_BOLD_CYAN}●${C_RESET}  ${C_BOLD}${options[$i]}${C_RESET}"
        else
            echo -e "  ${C_DIM}○${C_RESET}  ${C_DIM}${options[$i]}${C_RESET}"
        fi
    done

    while true; do
        IFS= read -r -s -n1 key 2>/dev/null || key=""
        if [[ "${key}" == $'\x1b' ]]; then
            IFS= read -r -s -n2 key2 2>/dev/null || key2=""
            key="${key}${key2}"
        fi

        case "${key}" in
            $'\x1b[A'|$'\x1b[D')  # Up / Left
                (( selected > 0 )) && (( selected-- )) || true
                _print_radio_menu
                ;;
            $'\x1b[B'|$'\x1b[C')  # Down / Right
                (( selected < num-1 )) && (( selected++ )) || true
                _print_radio_menu
                ;;
            "")  # Enter
                break
                ;;
        esac
    done

    stty "${old_stty}" 2>/dev/null || true
    _result_ref="${options[$selected]}"
    ok "  → ${_result_ref}"
    echo ""
}

# ---------------------------------------------------------------------------
# Multi-select menu (checkboxes)
# Usage: select_many RESULT_ARRAY "Prompt" option1 option2 ...
# Sets RESULT_ARRAY to array of selected options
# ---------------------------------------------------------------------------
select_many() {
    local -n _result_arr="$1"; shift
    local prompt="$1"; shift
    local options=("$@")
    local num="${#options[@]}"
    local selected=0
    local checked=()
    for (( i=0; i<num; i++ )); do checked+=( 0 ); done
    # Default: check first item
    checked[0]=1

    if ! is_interactive; then
        _result_arr=("${options[0]}")
        return 0
    fi

    local old_stty
    old_stty="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon 2>/dev/null || true

    _print_check_menu() {
        for (( i=0; i<num+3; i++ )); do
            echo -ne "\033[1A\033[2K"
        done
        echo -e "${C_BOLD}${prompt}${C_RESET}"
        echo -e "${C_DIM}  Space to toggle, Enter to confirm${C_RESET}"
        echo ""
        for (( i=0; i<num; i++ )); do
            local box="${C_DIM}☐${C_RESET}"
            [[ "${checked[$i]}" == "1" ]] && box="${C_BOLD_GREEN}☑${C_RESET}"
            if (( i == selected )); then
                echo -e "  ${box}  ${C_BOLD}${options[$i]}${C_RESET} ${C_CYAN}◀${C_RESET}"
            else
                echo -e "  ${box}  ${C_DIM}${options[$i]}${C_RESET}"
            fi
        done
    }

    # Initial draw
    echo -e "${C_BOLD}${prompt}${C_RESET}"
    echo -e "${C_DIM}  Space to toggle, Enter to confirm${C_RESET}"
    echo ""
    for (( i=0; i<num; i++ )); do
        local box="${C_DIM}☐${C_RESET}"
        [[ "${checked[$i]}" == "1" ]] && box="${C_BOLD_GREEN}☑${C_RESET}"
        if (( i == 0 )); then
            echo -e "  ${box}  ${C_BOLD}${options[$i]}${C_RESET} ${C_CYAN}◀${C_RESET}"
        else
            echo -e "  ${box}  ${C_DIM}${options[$i]}${C_RESET}"
        fi
    done

    local key
    while true; do
        IFS= read -r -s -n1 key 2>/dev/null || key=""
        if [[ "${key}" == $'\x1b' ]]; then
            IFS= read -r -s -n2 key2 2>/dev/null || key2=""
            key="${key}${key2}"
        fi

        case "${key}" in
            $'\x1b[A')  # Up
                (( selected > 0 )) && (( selected-- )) || true
                _print_check_menu
                ;;
            $'\x1b[B')  # Down
                (( selected < num-1 )) && (( selected++ )) || true
                _print_check_menu
                ;;
            " ")  # Space — toggle
                if [[ "${checked[$selected]}" == "1" ]]; then
                    checked[$selected]=0
                else
                    checked[$selected]=1
                fi
                _print_check_menu
                ;;
            "")  # Enter
                break
                ;;
        esac
    done

    stty "${old_stty}" 2>/dev/null || true
    _result_arr=()
    for (( i=0; i<num; i++ )); do
        [[ "${checked[$i]}" == "1" ]] && _result_arr+=("${options[$i]}")
    done

    if [[ ${#_result_arr[@]} -gt 0 ]]; then
        ok "  → ${_result_arr[*]}"
    else
        warn "  → (none selected)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Simple Yes/No confirmation
# Usage: confirm "Are you sure?" [default=y|n]
# Returns 0 for yes, 1 for no
# ---------------------------------------------------------------------------
confirm() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "${MOODLEKIT_YES:-0}" == "1" ]]; then
        return 0
    fi

    if ! is_interactive; then
        [[ "${default}" == "y" ]] && return 0 || return 1
    fi

    local yn_prompt
    [[ "${default}" == "y" ]] && yn_prompt="[Y/n]" || yn_prompt="[y/N]"

    echo -ne "${C_BOLD}${prompt}${C_RESET} ${C_DIM}${yn_prompt}${C_RESET} "
    local input
    read -r input
    input="${input,,}"  # lowercase

    if [[ -z "${input}" ]]; then
        [[ "${default}" == "y" ]] && return 0 || return 1
    fi

    [[ "${input}" == "y" || "${input}" == "yes" ]] && return 0 || return 1
}

# ---------------------------------------------------------------------------
# Text input with optional validation regex
# Usage: input_text RESULT_VAR "Prompt" [default] [validation_regex] [error_msg]
# ---------------------------------------------------------------------------
input_text() {
    local -n _text_ref="$1"; shift
    local prompt="$1"
    local default="${2:-}"
    local regex="${3:-}"
    local err_msg="${4:-Invalid input. Try again.}"

    if [[ "${MOODLEKIT_YES:-0}" == "1" ]] && [[ -n "${default}" ]]; then
        _text_ref="${default}"
        return 0
    fi

    local default_hint=""
    [[ -n "${default}" ]] && default_hint=" ${C_DIM}[${default}]${C_RESET}"

    while true; do
        echo -ne "${C_BOLD}${prompt}${C_RESET}${default_hint}: "
        local input
        read -r input
        [[ -z "${input}" && -n "${default}" ]] && input="${default}"

        if [[ -n "${regex}" && ! "${input}" =~ ${regex} ]]; then
            warn "${err_msg}"
            continue
        fi

        if [[ -z "${input}" ]]; then
            if [[ -n "${regex}" && "${input}" =~ ${regex} ]]; then
                # Regex explicitly allows empty input
                :
            else
                warn "Input cannot be empty."
                continue
            fi
        fi

        _text_ref="${input}"
        break
    done
}

# ---------------------------------------------------------------------------
# Path input with Tab-completion (readline mode)
# Usage: input_path RESULT_VAR "Prompt" [default]
# Uses `read -e` so the user can press Tab to browse the filesystem.
# ---------------------------------------------------------------------------
input_path() {
    local -n _path_ref="$1"; shift
    local prompt="$1"
    local default="${2:-}"

    if [[ "${MOODLEKIT_YES:-0}" == "1" ]] && [[ -n "${default}" ]]; then
        _path_ref="${default}"
        return 0
    fi

    local default_hint=""
    [[ -n "${default}" ]] && default_hint=" ${C_DIM}[${default}]${C_RESET}"

    while true; do
        echo -ne "${C_BOLD}${prompt}${C_RESET}${default_hint}: "
        local input
        # -e enables readline (Tab completion), -i pre-seeds the default value
        if [[ -n "${default}" ]]; then
            read -e -r -i "${default}" input
        else
            read -e -r input
        fi

        [[ -z "${input}" && -n "${default}" ]] && input="${default}"

        if [[ -z "${input}" ]]; then
            warn "Path cannot be empty."
            continue
        fi

        _path_ref="${input}"
        break
    done
}


# ---------------------------------------------------------------------------
# Spinner for long operations
# Usage: spinner_start "Message"
#        ... do work ...
#        spinner_stop [0=success|1=fail]
# ---------------------------------------------------------------------------
_SPINNER_PID=""

spinner_start() {
    local msg="${1:-Working...}"
    if ! is_interactive; then
        info "${msg}"
        return 0
    fi

    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            echo -ne "\r  ${C_BOLD_CYAN}${frames[$i]}${C_RESET}  ${msg}   "
            i=$(( (i+1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    _SPINNER_PID=$!
    disown "${_SPINNER_PID}" 2>/dev/null || true
}

spinner_stop() {
    local success="${1:-0}"
    if [[ -n "${_SPINNER_PID}" ]]; then
        kill "${_SPINNER_PID}" 2>/dev/null || true
        wait "${_SPINNER_PID}" 2>/dev/null || true
        _SPINNER_PID=""
    fi
    echo -ne "\r\033[2K"  # Clear spinner line
    if [[ "${success}" == "0" ]]; then
        ok "$2"
    else
        err "$2"
    fi
}

# ---------------------------------------------------------------------------
# Text-based progress bar
# Usage: progress_bar current total [label]
# ---------------------------------------------------------------------------
progress_bar() {
    local current="$1"
    local total="$2"
    local label="${3:-Progress}"
    local width=40

    [[ "${total}" -eq 0 ]] && return 0

    local pct=$(( current * 100 / total ))
    local filled=$(( current * width / total ))
    local empty=$(( width - filled ))

    local bar=""
    bar+="${C_BOLD_GREEN}"
    for (( i=0; i<filled; i++ )); do bar+="█"; done
    bar+="${C_DIM}"
    for (( i=0; i<empty; i++ )); do bar+="░"; done
    bar+="${C_RESET}"

    echo -ne "\r  ${bar}  ${C_BOLD}${pct}%%${C_RESET}  ${C_DIM}${label} (${current}/${total})${C_RESET}"
    [[ "${current}" -ge "${total}" ]] && echo ""
}
