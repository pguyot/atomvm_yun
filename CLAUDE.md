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

## Hardware gotchas

- The hat I2C bus is SDA=G0, SCL=G26 — **G0 is the ESP32 boot-strapping
  pin**. A stuck I2C slave holding SDA low traps the ESP32 in download
  mode (`boot:0x3 DOWNLOAD_BOOT`). Recovery without touching hardware:
  bit-bang ~10 SCL pulses + a STOP through the ROM loader by toggling
  GPIO output-enables (esptool `write_reg` on GPIO_ENABLE_W1TS/W1TC,
  OUT bits 0/26 held 0) — this released the bus when it happened.
- The STM32 low-power firmware can latch BUSY (errata DM00091791) when
  ULP bus traffic wakes it mid-transaction; it then NACKs everything
  and never auto-sleeps. Firmware v2 follow-up: wait for bus idle
  before re-enabling I2C on wake + a stuck-BUSY watchdog (PE toggle).
  Until then the app talks to the hat before running the ULP.
- SHT20/BMP280 answer the ULP bit-bang but NACK the esp-idf i2c driver
  on the same pins (STM32 answers both) — unexplained, non-blocking
  since the SHT20 is read via ULP by design.
- ULP programs re-run on the ULP wake timer unless the program disables
  it (`?I_WR_RTC_CNTL_ULP_CP_SLP_TIMER_EN(0)` before `?I_HALT`) — and
  the RTC domain (loaded program, timer, pad holds) survives EN-pin
  resets; only a full power-off clears it.

## Build

- Firmware: `cmake -B build && cmake --build build` in `YUN/` (MacPorts
  `arm-none-eabi-gcc`; flash with MacPorts `st-flash`, see `YUN/README.md`).
- The AtomVM esp32 image is built from ~/AtomVM (`idf.py build` /
  `idf.py -p PORT -b 1500000 flash` with ESP-IDF from ~/esp/esp-idf).
  `atomvm_ulp` is symlinked into its components/ from this repo's
  `_checkouts/atomvm_ulp` (which overrides the rebar dep and carries
  local changes); ULP FSM is enabled in its sdkconfig.
- Erlang app: `rebar3 packbeam`, then
  `rebar3 esp32_flash -p /dev/cu.usbserial-* -o 0x250000`.
  The offset MUST be 0x250000 (main.avm in the custom AtomVM partition
  table built from ~/AtomVM); the plugin default 0x210000 would corrupt
  boot.avm.
