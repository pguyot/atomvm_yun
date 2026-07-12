-module(atomvm_yun).

-export([start/0, test_yun_hat/0]).

-include_lib("atomvm_ulp/include/ulp.hrl").

-define(GPIO_SHT20_I2C_SCL, 26).
-define(GPIO_SHT20_I2C_SDA, 0).
-define(RTC_GPIO_SHT20_I2C_SCL, 7).
-define(RTC_GPIO_SHT20_I2C_SDA, 11).

% BtnA on the M5StickC Plus, active low, RTC-capable (deep sleep wake)
-define(GPIO_BTN_A, 37).

% How long the reading stays on screen before going back to deep sleep
-define(DISPLAY_TIMEOUT_MS, 20000).

% Thermometer: wakes on BtnA, reads the SHT20 through the ULP, shows the
% temperature big with a battery gauge top-right, then deep-sleeps again.
start() ->
    m5:begin_([{clear_display, true}]),
    m5_display:set_epd_mode(fastest),
    m5_display:set_brightness(128),

    case m5_display:width() < m5_display:height() of
        true ->
            % Landscape mode
            m5_display:set_rotation(m5_display:get_rotation() bxor 1);
        false ->
            ok
    end,

    io:format("wakeup cause: ~p\n", [esp:sleep_get_wakeup_cause()]),

    Battery = m5_power:get_battery_level(),
    Reading =
        try measure_temperature() of
            Raw when Raw >= 16#FFF0 -> {error, Raw};
            Raw -> {ok, Raw}
        catch
            exit:timeout -> {error, timeout}
        end,
    io:format("battery: ~p, reading: ~p\n", [Battery, Reading]),
    draw_ui(Reading, Battery),

    timer:sleep(?DISPLAY_TIMEOUT_MS),
    m5_display:sleep(),
    ok = esp:sleep_enable_ext0_wakeup(?GPIO_BTN_A, 0),
    esp:deep_sleep().

% SHT20: T = -46.85 + 175.72 * S / 2^16, with the 2 status bits cleared.
% Returns tenths of a degree Celsius as an integer.
raw_to_tenths(Raw) ->
    round(((175.72 * (Raw band 16#FFFC)) / 65536 - 46.85) * 10).

draw_ui({ok, Raw}, Battery) ->
    Tenths = raw_to_tenths(Raw),
    Str = list_to_binary(
        io_lib:format("~B.~B", [Tenths div 10, abs(Tenths rem 10)])
    ),
    io:format("temperature: ~s C\n", [Str]),
    m5_display:start_write(),
    m5_display:fill_screen(16#000000),
    draw_battery(Battery),
    m5_display:set_text_size(1),
    m5_display:draw_string(<<"SHT20">>, 8, 8),
    % 6x8 font at size 6: 36x48 px per character
    m5_display:set_text_size(6),
    CharW = 36,
    DegR = 5,
    TempW = CharW * byte_size(Str),
    TotalW = TempW + 2 * DegR + 4 + CharW,
    X0 = max(0, (m5_display:width() - TotalW) div 2),
    Y0 = (m5_display:height() - 48) div 2 + 4,
    m5_display:draw_string(Str, X0, Y0),
    DegX = X0 + TempW + DegR + 2,
    m5_display:draw_circle(DegX, Y0 + DegR, DegR, 16#FFFFFF),
    m5_display:draw_string(<<"C">>, DegX + DegR + 2, Y0),
    m5_display:end_write();
draw_ui({error, Reason}, Battery) ->
    io:format("measurement failed: ~p\n", [Reason]),
    m5_display:start_write(),
    m5_display:fill_screen(16#000000),
    draw_battery(Battery),
    m5_display:set_text_size(2),
    m5_display:draw_string(<<"sensor error">>, 30, 60),
    m5_display:end_write().

% Battery gauge in the top-right corner: outline + nub, fill colored by
% level, with the percentage in small text to its left.
draw_battery(Level) when is_integer(Level), Level >= 0, Level =< 100 ->
    X = m5_display:width() - 34,
    Y = 8,
    m5_display:draw_rect(X, Y, 26, 14, 16#FFFFFF),
    m5_display:fill_rect(X + 26, Y + 4, 3, 6, 16#FFFFFF),
    Color =
        if
            Level > 50 -> 16#00C853;
            Level > 20 -> 16#FFD600;
            true -> 16#FF1744
        end,
    FillW = max(1, (22 * Level) div 100),
    m5_display:fill_rect(X + 2, Y + 2, FillW, 10, Color),
    m5_display:set_text_size(1),
    Pct = list_to_binary(io_lib:format("~B%", [Level])),
    m5_display:draw_string(Pct, X - 4 - 6 * byte_size(Pct), Y + 4);
draw_battery(_Unknown) ->
    ok.

% Exercise the YUN Hat STM32 running the low-power firmware (YUN/README.md):
% version read proves the wake-retry works, LEDs prove 0x01 is intact, light
% proves the ADC restarts after Stop mode.
test_yun_hat() ->
    ok = yun_hat:open(),
    m5_display:start_write(),
    case yun_hat:version() of
        {ok, Version} ->
            io:format("YUN hat firmware version ~B\n", [Version]),
            m5_display:print(<<"Hat FW:">>),
            m5_display:println(integer_to_binary(Version)),
            ok = yun_hat:set_all({0, 16, 0}),
            case yun_hat:light() of
                {ok, Light} ->
                    io:format("YUN hat light = ~B\n", [Light]),
                    m5_display:print(<<"Light:">>),
                    m5_display:println(integer_to_binary(Light));
                error ->
                    io:format("YUN hat light read failed\n"),
                    m5_display:println(<<"Light:ERR">>)
            end,
            ok = yun_hat:sleep();
        error ->
            io:format("YUN hat version read failed (factory firmware?)\n"),
            m5_display:println(<<"Hat FW:ERR">>)
    end,
    m5_display:end_write().

measure_temperature() ->
    {ULPBinary, _Labels} = ulp:compile([
        {label, read_value},
        % read value: high bits
        <<0:32>>,
        % read value: low bits
        <<0:32>>,

        {movi, 2, next0},
        {bxi, i2c_start},
        {label, next0},
        
        % Write address (0x40, R/W=0: write)
        ?I_MOVI(1, 2#10000000), % byte to write

        {movi, 2, next1},
        {bxi, write_byte},
        {label, next1},

        % Abort if NACK
        ?I_JUMPR_LT(3, 1),
        ?I_MOVI(1, 16#FFFE),
        {bxi, error_x},

        % Write command
        ?I_MOVI(1, 2#11100011),

        {movi, 2, next2},
        {bxi, write_byte},
        {label, next2},

        % Abort if NACK
        ?I_JUMPR_LT(3, 1),
        ?I_MOVI(1, 16#FFFD),
        {bxi, error_x},

        {movi, 2, next3},
        {bxi, i2c_stop},
        {label, next3},

        {movi, 2, next4},
        {bxi, i2c_start},
        {label, next4},

        % Write address (0x40, R/W=1: read)
        ?I_MOVI(1, 2#10000001),

        {movi, 2, next5},
        {bxi, write_byte},
        {label, next5},

        ?I_MOVI(1, 0),
        ?I_MOVI(3, 0),  % ACK

        % Read byte
        {movi, 2, next6},
        {bxi, read_byte},
        {label, next6},

        % Read byte
        {movi, 2, next7},
        {bxi, read_byte},
        {label, next7},

        {movi, 3, read_value},
        ?I_ST(1, 3, 0),

        ?I_MOVI(1, 0),
        ?I_MOVI(3, 1),  % NACK

        % Read byte
        {movi, 2, next8},
        {bxi, read_byte},
        {label, next8},

        {movi, 3, read_value},
        ?I_ST(1, 3, 1),

        {movi, 2, next9},
        {bxi, i2c_stop},
        {label, next9},

        % One-shot: disable the ULP wakeup timer so the program doesn't
        % re-run and bit-bang over the hardware I2C driver.
        ?I_WR_RTC_CNTL_ULP_CP_SLP_TIMER_EN(0),
        ?I_WAKE,
        ?I_HALT,

        % I2C Start
        % Returns to address set by R2.
        % On exit, SCL and SDA are driven low
        {label, i2c_start},
        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Drive SDA low
        ?I_WR_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        % Drive SCL low
        ?I_WR_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        % Return
        ?I_BXR(2),

        % I2C Stop
        % Returns to address set by R2.
        {label, i2c_stop},
        % Drive SDA low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Ensure SDA is high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, i2c_stop_exit, 1},
        {bxi, arbitration_lost},
        % Return
        {label, i2c_stop_exit},
        ?I_BXR(2),

        % Write a byte
        % Returns to address set by R2.
        % Byte to write is in R1
        % Stage counter and R0 are modified
        % On exit, SCL is high
        {label, write_byte},
        ?I_STAGE_RST,

        {label, write_byte_loop},
        ?I_ANDI(0, 1, 16#80),
        ?I_STAGE_INC(1),
        ?I_LSHI(1, 1, 1),

        {jumpr_ge, write_bit_high, 1},
        % Drive SDA low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        {bxi, write_byte_loop_continue},

        {label, write_bit_high},
        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Ensure SDA is high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, write_byte_loop_continue, 1},
        {bxi, arbitration_lost},

        {label, write_byte_loop_continue},
        % Drive SCL low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        {jumps_lt, write_byte_loop, 8},

        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Read ACK/NACK
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        % Drive SCL low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        % Return
        ?I_BXR(2),

        % Read a byte
        % R3 determines if it's ACK or NACK
        % Byte is put into R1 which is shifted by 8 bits
        % R0 is used
        % Return address is R2.
        {label, read_byte},
        ?I_STAGE_RST,
        {label, read_byte_loop},
        % Shift before OR-ing the new bit in, so the last bit isn't
        % over-shifted (R1 accumulates across both data bytes).
        ?I_LSHI(1, 1, 1),
        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Read SDA
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        ?I_ORR(1, 1, 0),
        % Drive SCL low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        ?I_STAGE_INC(1),
        {jumps_lt, read_byte_loop, 8},

        % Write ACK or NACK (R3)
        ?I_MOVR(0, 3),
        {jumpr_ge, read_byte_nack, 1},
        % Write ACK
        % Drive SDA low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        {bxi, read_byte_exit},

        {label, read_byte_nack},
        % Let SDA be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        % Let SCL be driven by pull up
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        % Wait for SCL to be high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        % Ensure SDA is high
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, read_byte_exit, 1},        
        {bxi, arbitration_lost},

        {label, read_byte_exit},
        % Drive SCL low
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        % Return
        ?I_BXR(2),

        {label, arbitration_lost},
        ?I_MOVI(1, 16#FFFF),
        {label, error_x},
        {movi, 3, read_value},
        ?I_ST(1, 3, 0),
        ?I_WR_RTC_CNTL_ULP_CP_SLP_TIMER_EN(0),
        ?I_WAKE,
        ?I_HALT
    ]),
    io:format("Program size = ~B\n", [byte_size(ULPBinary)]),
    ulp:load_binary(ULPBinary),
    ?RTC_GPIO_SHT20_I2C_SCL = rtc_gpio:gpio_to_rtc_gpio(?GPIO_SHT20_I2C_SCL),
    ?RTC_GPIO_SHT20_I2C_SDA = rtc_gpio:gpio_to_rtc_gpio(?GPIO_SHT20_I2C_SDA),
    % configure pins
    rtc_gpio:init(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:set_direction(?GPIO_SHT20_I2C_SCL, input_output),
    rtc_gpio:pulldown_dis(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:pullup_en(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:init(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:set_direction(?GPIO_SHT20_I2C_SDA, input_output),
    rtc_gpio:pulldown_dis(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:pullup_en(?GPIO_SHT20_I2C_SDA),
    {ok, {Handler, Ref}} = ulp:isr_register(),
    ulp:run(2),
    receive
        {ulp, Ref} ->
            true = ulp:isr_deregister(Handler),
            Mem0 = ulp:read_memory(0),
            % read_value[0] = 16-bit raw temperature (or an 16#FFFx error
            % sentinel), read_value[1] = CRC byte, unchecked for now
            Mem0 band 16#FFFF
    after 1000 ->
        exit(timeout)
    end.
