default: help

help:
    ./clock_ticker.sh help

test:
    ./clock_ticker.sh test

install target="":
    config_dir="${XDG_CONFIG_HOME:-$HOME/.config}/clock-ticker"
    mkdir -p "$config_dir/modules"
    if [ ! -e ./personal_modules ] && [ ! -L ./personal_modules ]; then ln -s "$config_dir/modules" ./personal_modules; fi
    uv sync
    ./clock_ticker.sh install "{{ target }}"

restart:
    ./clock_ticker.sh restart

stop:
    ./clock_ticker.sh stop

update module:
    ./clock_ticker.sh update {{ module }}
