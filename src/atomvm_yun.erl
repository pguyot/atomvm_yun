-module(atomvm_yun).

-export([start/0, test_yun_hat/0]).

% BtnA on the M5StickC Plus, active low, RTC-capable (deep sleep wake)
-define(GPIO_BTN_A, 37).

% How long the reading stays on screen before going back to deep sleep
-define(DISPLAY_TIMEOUT_MS, 3000).

% Thermometer: the ULP sampler (yun_sampler) reads the SHT20 every 5
% minutes into a ring in RTC memory while everything sleeps. A BtnA wake
% shows the temperature big with a battery gauge; timer wakes (hourly
% harvest) will keep the display dark.
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

    Loaded = yun_sampler:ensure_loaded(),
    io:format("sampler: ~p, count: ~p\n", [Loaded, yun_sampler:sample_count()]),

    % First contact fenced from the ULP sampler; also logs which hat
    % firmware is mounted.
    ok = yun_sampler:acquire_bus(),
    ok = yun_hat:open(),
    io:format("hat firmware: ~p\n", [yun_hat:version()]),
    ok = yun_sampler:release_bus(),

    Battery = m5_power:get_battery_level(),
    % Display the ring's latest sample (<= 5 min old) rather than forcing
    % a manual one: manual samples would pollute the log's 5-min cadence.
    % Only a cold boot with an empty ring waits for a fresh sample.
    Reading =
        case yun_sampler:latest() of
            {error, no_sample_yet} -> yun_sampler:sample_now(3000);
            Latest -> Latest
        end,
    io:format("battery: ~p, reading: ~p\n", [Battery, Reading]),
    {Count, Recent} = yun_sampler:harvest((yun_sampler:sample_count() - 3) band 16#FFFF),
    io:format("ring tail (count ~B): ~p\n", [Count, Recent]),
    draw_ui(Reading, Battery),

    timer:sleep(?DISPLAY_TIMEOUT_MS),
    m5_display:sleep(),
    ok = esp:sleep_enable_ext0_wakeup(?GPIO_BTN_A, 0),
    esp:deep_sleep().

% Tenths of a degree Celsius from the raw SHT20 sample.
raw_to_tenths(Raw) ->
    (yun_sampler:raw_to_millicelsius(Raw) + 50) div 100.

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
