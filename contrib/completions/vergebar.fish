# Completions for vergebar
complete -c vergebar -s c -l config -d "Path to config file" -r -F
complete -c vergebar -s s -l style -d "Path to stylesheet" -r -F
complete -c vergebar -s l -l log-level -d "Set logging level" -x -a "debug info warn error"
complete -c vergebar -l validate-config -d "Validate configuration syntax without running"
complete -c vergebar -l list-modules -d "List all built-in modules"
complete -c vergebar -l dump-default-config -d "Print default config.jsonc to stdout"
complete -c vergebar -l dump-default-style -d "Print default style.css to stdout"
complete -c vergebar -s h -l help -d "Show help message"
complete -c vergebar -l version -d "Show version information"
