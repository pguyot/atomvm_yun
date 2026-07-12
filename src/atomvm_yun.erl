-module(atomvm_yun).

-export([start/0]).

-include_lib("atomvm_ulp/include/ulp.hrl").

-define(GPIO_SHT20_I2C_SCL, 26).
-define(GPIO_SHT20_I2C_SDA, 0).
-define(RTC_GPIO_SHT20_I2C_SCL, 7).
-define(RTC_GPIO_SHT20_I2C_SDA, 11).

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

    TextSize0 = floor(m5_display:height() / 160),
    TextSize = max(1, TextSize0),
    m5_display:set_text_size(TextSize),

    Name = atom_to_list(m5:get_board()),
    m5_display:start_write(),

    m5_display:print(<<"Core:">>),
    m5_display:println(Name),

    IMUName = atom_to_list(m5_imu:get_type()),
    m5_display:print(<<"IMU:">>),
    m5_display:println(IMUName),

    m5_display:end_write(),

    % Talk to the hat STM32 before the ULP bit-bangs the shared bus: its
    % traffic wakes the STM32 mid-transaction, which can latch BUSY
    % (errata DM00091791) until the firmware learns to recover from it.
    test_yun_hat(),

    try
        Temperature = measure_temperature(),
    
        m5_display:start_write(),

        m5_display:print(<<"Temperature:">>),
        m5_display:println(integer_to_binary(Temperature)),

        m5_display:end_write()
    catch exit:timeout ->
        m5_display:start_write(),
        m5_display:println(<<"TIMEOUT">>),
        m5_display:end_write()
    end,

    timer:sleep(5000),
    m5_power:deep_sleep(),
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
            io:format("Mem0 = ~8.16.0B\n", [Mem0]),
            Val0 = Mem0 band 16#FFFF,
            Mem1 = ulp:read_memory(1),
            Val1 = Mem1 band 16#FFFF,
            io:format("Mem1 = ~8.16.0B\n", [Mem1]),
            Val = Val0 bsl 16 + Val1,
            io:format("Val = ~8.16.0B\n", [Val]),
            Val
    after 1000 ->
        exit(timeout)
    end.
