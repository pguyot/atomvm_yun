%
% Driver for the M5StickC YUN Hat STM32 (I2C slave at 0x38).
%
% Uses the atomvm_m5 m5_ex_i2c primitives (M5Unified Ex_I2C on the hat
% pins), since AtomVM's own i2c driver cannot coexist with the new esp-idf
% driver M5Unified uses.
%
% With the low-power firmware (YUN/README.md) the STM32 sleeps in Stop mode
% after 500 ms of bus inactivity; the first transaction addressed to it only
% wakes it up and is NACKed, so every command here retries once.
%
% The firmware processes a command only after the STOP condition, so reads
% are performed as a write transaction followed by a separate read
% transaction — never a repeated START.
%
-module(yun_hat).

-export([
    open/0,
    close/0,
    version/0,
    set_led/2,
    set_all/1,
    light/0,
    sleep/0
]).

-define(YUN_HAT_ADDR, 16#38).
-define(I2C_FREQ, 100000).

-define(CMD_READ_LIGHT, 16#00).
-define(CMD_SET_LED, 16#01).
-define(CMD_SLEEP, 16#02).
-define(CMD_READ_VERSION, 16#FE).

% Hat connector I2C bus (shared with the SHT20 and BMP280).
% In_I2C claims port 1 on the ESP32, so Ex_I2C gets port 0.
-define(I2C_PORT, 0).
-define(GPIO_HAT_I2C_SDA, 0).
-define(GPIO_HAT_I2C_SCL, 26).

-define(WAKE_RETRY_DELAY_MS, 2).

-spec open() -> ok | error.
open() ->
    case m5_ex_i2c:begin_(?I2C_PORT, ?GPIO_HAT_I2C_SDA, ?GPIO_HAT_I2C_SCL) of
        ok -> ok;
        true -> ok;
        _ -> error
    end.

-spec close() -> ok.
close() ->
    m5_ex_i2c:release(),
    ok.

% Returns the firmware version byte. The factory firmware doesn't implement
% this command (reads back garbage/0), the low-power firmware returns >= 1.
-spec version() -> {ok, non_neg_integer()} | error.
version() ->
    case read_command(<<?CMD_READ_VERSION>>, 1) of
        {ok, <<Version>>} -> {ok, Version};
        _ -> error
    end.

% Set a single LED (0..13). Color is {R, G, B}, 0..255 each.
-spec set_led(0..13, {byte(), byte(), byte()}) -> ok | error.
set_led(Num, {R, G, B}) when Num >= 0 andalso Num =< 13 ->
    write_command(<<?CMD_SET_LED, Num, R, G, B>>).

% Set all 14 LEDs to the same color.
-spec set_all({byte(), byte(), byte()}) -> ok | error.
set_all({R, G, B}) ->
    write_command(<<?CMD_SET_LED, 16#FF, R, G, B>>).

% Read the light sensor (12-bit ADC average, little-endian on the wire).
-spec light() -> {ok, non_neg_integer()} | error.
light() ->
    case read_command(<<?CMD_READ_LIGHT>>, 2) of
        {ok, <<Value:16/little>>} -> {ok, Value};
        _ -> error
    end.

% Put the STM32 into Stop mode immediately (it would auto-sleep after 500 ms
% anyway). Any subsequent command wakes it.
-spec sleep() -> ok | error.
sleep() ->
    write_command(<<?CMD_SLEEP>>).

%
% Internal.
%

% Write with a single retry: a sleeping STM32 NACKs the transaction that
% wakes it, and is listening again well within a couple of milliseconds.
write_command(Data) ->
    case raw_write(Data) of
        true ->
            ok;
        false ->
            timer:sleep(?WAKE_RETRY_DELAY_MS),
            case raw_write(Data) of
                true -> ok;
                false -> error
            end
    end.

% Command followed by a read-back, as two separate STOP-terminated
% transactions (the firmware only interprets the command after STOP).
read_command(Command, ReadLen) ->
    case write_command(Command) of
        ok -> raw_read(ReadLen);
        error -> error
    end.

raw_write(Data) ->
    Started = m5_ex_i2c:start(?YUN_HAT_ADDR, false, ?I2C_FREQ),
    Written = Started andalso m5_ex_i2c:write(Data),
    Stopped = m5_ex_i2c:stop(),
    Written andalso Stopped.

raw_read(Len) ->
    Started = m5_ex_i2c:start(?YUN_HAT_ADDR, true, ?I2C_FREQ),
    Result =
        case Started of
            true -> m5_ex_i2c:read(Len, true);
            false -> false
        end,
    Stopped = m5_ex_i2c:stop(),
    case {Result, Stopped} of
        {{ok, Data}, true} -> {ok, Data};
        _ -> error
    end.
