# YUN Hat low-power firmware

Modified firmware for the STM32F030F4P6 on the M5StickC YUN Hat (I2C slave at
0x38, 14 SK6812 LEDs, light-sensor ADC). The factory firmware spins at 64 MHz
with the ADC in continuous mode and never sleeps, which heats the board (skewing
the SHT20) and drains the battery. This version enters Stop mode (~5 µA) after
500 ms of I2C inactivity and wakes on SDA activity (EXTI on PA10 — the F030's
I2C cannot wake from Stop by itself).

**Protocol** (backwards compatible with factory):

| Command | Write | Read back |
|---------|-------|-----------|
| `0x00` | `[0x00]` | 2 bytes, light-sensor value (little-endian) |
| `0x01` | `[0x01, led, R, G, B]` (led > 13 = all) | — |
| `0x02` | `[0x02]` | — (sleep immediately) |
| `0xFE` | `[0xFE]` | 1 byte, firmware version (factory firmware ignores it) |

A transaction addressed to a *sleeping* STM32 is missed once (it only wakes the
chip); the master must retry — `src/yun_hat.erl` does this. After reset the
chip stays awake 3 s before the first auto-sleep so SWD attach is easy.

## Tools (MacPorts)

`arm-none-eabi-gcc` and `stlink` (`st-info`, `st-flash`), in `/opt/local/bin`.

## Wiring

The 5 solder pads on the back connect to the ST-Link: GND, 3V3 (power the hat
from the dongle — do **not** flash while the hat is on the stick), SWDIO
(PA13, TSSOP20 pin 19), SWCLK (PA14, pin 20), NRST (pin 4). Identify pads with
a multimeter first; probe with:

```sh
st-info --probe
```

## Backup the factory firmware (once, before anything else)

```sh
st-flash read yun_factory_backup.bin 0x08000000 0x4000
```

If the chip is read-protected this fails; a mass-erase (OpenOCD) is then needed
before flashing, and there is no going back on this unit.

## Build

```sh
cmake -B build
cmake --build build     # produces build/yun.bin, prints size (must fit 16 KB)
```

## Flash

```sh
st-flash --reset write build/yun.bin 0x08000000
```

Once the low-power firmware is running, the chip is usually in Stop mode and
SWD needs a reset to attach — either flash within the 3 s boot grace period or
use:

```sh
st-flash --connect-under-reset --reset write build/yun.bin 0x08000000
```

## Restore factory firmware

```sh
st-flash --connect-under-reset --reset write yun_factory_backup.bin 0x08000000
```
