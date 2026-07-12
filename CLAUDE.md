# atomvm_yun

AtomVM app for the M5StickC with the YUN Hat, plus modified low-power firmware
for the hat's STM32F030F4 (`YUN/`, see `YUN/README.md`). `YUN_ORIG/` is an
untracked pristine copy of the factory source (also preserved as the initial
git commit). `yun_factory_backup.bin` is the factory flash image read from the
chip — never delete it.

## Conventions

- Address Paul by his first name in every message.
- Commits: `git commit -s -S` (signoff + GPG signature).
- No "Co-Authored-By" trailers and no Claude session links in commit messages.

## Build

- Firmware: `cmake -B build && cmake --build build` in `YUN/` (MacPorts
  `arm-none-eabi-gcc`; flash with MacPorts `st-flash`, see `YUN/README.md`).
- Erlang app: `rebar3` with the atomvm_rebar3_plugin.
