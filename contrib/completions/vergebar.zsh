#compdef vergebar

_vergebar() {
    local -a arguments

    arguments=(
        '(-c --config)'{-c,--config}'[Path to config file]:config file:_files -g "*.jsonc *.json"'
        '(-s --style)'{-s,--style}'[Path to stylesheet]:CSS file:_files -g "*.css"'
        '(-l --log-level)'{-l,--log-level}'[Set logging level]:level:(debug info warn error)'
        '--validate-config[Validate configuration syntax without running]'
        '--list-modules[List all built-in modules]'
        '--dump-default-config[Print default config.jsonc to stdout]'
        '--dump-default-style[Print default style.css to stdout]'
        '(-h --help)'{-h,--help}'[Show help message]'
        '--version[Show version information]'
    )

    _arguments -s $arguments
}

_vergebar "$@"
