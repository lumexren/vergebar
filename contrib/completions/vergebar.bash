_vergebar() {
    local cur prev opts
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    opts="-c --config -s --style -l --log-level --version -h --help --validate-config --list-modules --dump-default-config --dump-default-style"

    case "${prev}" in
        -c|--config)
            COMPREPLY=( $(compgen -f -X '!*.json?(c)' -- "${cur}") $(compgen -f -- "${cur}") )
            return 0
            ;;
        -s|--style)
            COMPREPLY=( $(compgen -f -X '!*.css' -- "${cur}") $(compgen -f -- "${cur}") )
            return 0
            ;;
        -l|--log-level)
            COMPREPLY=( $(compgen -W "debug info warn error" -- "${cur}") )
            return 0
            ;;
        *)
            ;;
    esac

    if [[ "${cur}" == -* ]] ; then
        COMPREPLY=( $(compgen -W "${opts}" -- "${cur}") )
        return 0
    fi
}

complete -F _vergebar vergebar
