%
% Driver for the M5StickC YUN Hat STM32 (I2C slave at 0x38).
%
% With the low-power firmware (YUN/README.md) the STM32 sleeps in Stop mode
% after 500 ms of bus inactivity; the first transaction addressed to it only
% wakes it up and is NACKed, so every command here retries once.
%
-module(yun_hat).

-export([
    open/0,
    close/1,
    version/1,
    set_led/3,
    set_all/2,
    light/1,
    sleep/1
]).

-define(YUN_HAT_ADDR, 16#38).

-define(CMD_READ_LIGHT, 16#00).
-define(CMD_SET_LED, 16#01).
-define(CMD_SLEEP, 16#02).
-define(CMD_READ_VERSION, 16#FE).

% Hat connector I2C bus (shared with the SHT20 and BMP280)
-define(GPIO_HAT_I2C_SDA, 0).
-define(GPIO_HAT_I2C_SCL, 26).

-define(WAKE_RETRY_DELAY_MS, 2).

-type i2c() :: pid().

-spec open() -> i2c().
open() ->
    i2c:open([
        {sda, ?GPIO_HAT_I2C_SDA},
        {scl, ?GPIO_HAT_I2C_SCL},
        {clock_speed_hz, 100000}
    ]).

-spec close(i2c()) -> ok.
close(I2C) ->
    i2c:close(I2C).

% Returns the firmware version byte. The factory firmware doesn't implement
% this command (reads back garbage/0), the low-power firmware returns >= 1.
-spec version(i2c()) -> {ok, non_neg_integer()} | {error, any()}.
version(I2C) ->
    case write_wake(I2C, <<?CMD_READ_VERSION>>) of
        ok ->
            case i2c:read_bytes(I2C, ?YUN_HAT_ADDR, 1) of
                {ok, <<Version>>} -> {ok, Version};
                Error -> Error
            end;
        Error ->
            Error
    end.

% Set a single LED (0..13). Color is {R, G, B}, 0..255 each.
-spec set_led(i2c(), 0..13, {byte(), byte(), byte()}) -> ok | {error, any()}.
set_led(I2C, Num, {R, G, B}) when Num >= 0 andalso Num =< 13 ->
    write_wake(I2C, <<?CMD_SET_LED, Num, R, G, B>>).

% Set all 14 LEDs to the same color.
-spec set_all(i2c(), {byte(), byte(), byte()}) -> ok | {error, any()}.
set_all(I2C, {R, G, B}) ->
    write_wake(I2C, <<?CMD_SET_LED, 16#FF, R, G, B>>).

% Read the light sensor (12-bit ADC average, little-endian on the wire).
-spec light(i2c()) -> {ok, non_neg_integer()} | {error, any()}.
light(I2C) ->
    case write_wake(I2C, <<?CMD_READ_LIGHT>>) of
        ok ->
            case i2c:read_bytes(I2C, ?YUN_HAT_ADDR, 2) of
                {ok, <<Value:16/little>>} -> {ok, Value};
                Error -> Error
            end;
        Error ->
            Error
    end.

% Put the STM32 into Stop mode immediately (it would auto-sleep after 500 ms
% anyway). Any subsequent command wakes it.
-spec sleep(i2c()) -> ok | {error, any()}.
sleep(I2C) ->
    write_wake(I2C, <<?CMD_SLEEP>>).

% Write with a single retry: a sleeping STM32 NACKs the transaction that
% wakes it, and is listening again well within a couple of milliseconds.
write_wake(I2C, Data) ->
    case i2c:write_bytes(I2C, ?YUN_HAT_ADDR, Data) of
        ok ->
            ok;
        _Error ->
            timer:sleep(?WAKE_RETRY_DELAY_MS),
            i2c:write_bytes(I2C, ?YUN_HAT_ADDR, Data)
    end.
