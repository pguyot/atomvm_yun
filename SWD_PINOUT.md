# M5StickC YUN HAT — SWD Pad Pinout

Reverse-engineered pinout of the 5 SWD-like pads on the back of the M5StickC **YUN HAT**
(SHT20 + BMP280 + photoresistor + 14× SK6812), which is driven by an
**STM32F030F4P6** (TSSOP-20, 16 KB flash / 4 KB RAM).

Verified working with an ST-Link V2: `st-info --probe` reports `chipid 0x0444` ("F0xx small").

## Pad map

Pads numbered from the **square pad** (pad 1 is square; pads 2–5 are round).

| Pad | Signal | STM32F030F4P6 leg |
|----:|--------|-------------------|
| 1 (□ square) | **3V3 / VDD** | 16 (VDD), 5 (VDDA) |
| 2 | **SWCLK** | 20 (PA14) |
| 3 | **SWDIO** | 19 (PA13) |
| 4 | **NRST** | 4 (NRST) |
| 5 | **GND / VSS** | 15 (VSS) |

## STM32F030F4P6 orientation (TSSOP-20, pin-1 dot at top-left)

```
                dot
                 ●
              ┌───────┐
     BOOT0  1 ┤●      ├ 20  PA14 ── SWCLK
   PF0/OSCI  2 ┤       ├ 19  PA13 ── SWDIO
   PF1/OSCO  3 ┤       ├ 18  PA10
     NRST   4 ┤       ├ 17  PA9
     VDDA   5 ┤       ├ 16  VDD  ── 3V3
     PA0    6 ┤       ├ 15  VSS  ── GND
     PA1    7 ┤       ├ 14  PB1
     PA2    8 ┤       ├ 13  PA7
     PA3    9 ┤       ├ 12  PA6
     PA4   10 ┤       ├ 11  PA5
              └───────┘
```

Pin numbering: down the left side (1→10), then up the right side (11→20).
BOOT0 is leg 1 (top-left, under the dot).

## Connecting a programmer (ST-Link / CMSIS-DAP)

Wire **SWDIO→pad 3, SWCLK→pad 2, GND→pad 5** (NRST→pad 4 optional).

**Power** — pick exactly one source, never two live at once:
- Power the HAT from the M5 stick (ST-Link 3V3 as sense/reference only), **or**
- Power from the ST-Link's 3.3 V into pad 1 (stick off).

The factory firmware keeps PA13/PA14 as Serial Wire and never sleeps, so a plain
`st-info --probe` attaches — **no BOOT0 trick or connect-under-reset required.**

## Bench notes / diode-mode fingerprints

- Continuity pad→leg: power/ground pads ≈ 0.008 V (dead short); SWCLK/SWDIO ≈ 0.07 V
  (small in-line series resistor).
- Idle levels with the **ST-Link disconnected** and board powered:
  - SWDIO (pad 3) idles **~3 V** (internal pull-up)
  - SWCLK (pad 2) idles **~0 V** (internal pull-down)
  - NRST (pad 4) idles **~3 V** (pull-up) — **0 V means the chip is held in reset**
    (e.g. a solder bridge to GND).

## Flashing

```sh
# Back up factory firmware first (whole 16 KB flash)
st-flash read yun-factory-backup.bin 0x08000000 0x4000

# Write new firmware
st-flash write firmware.bin 0x08000000
# or for Intel HEX:
st-flash --format ihex write firmware.hex
```
