-module(atomvm_yun).

-export([start/0, test_yun_hat/0]).

% BtnA on the M5StickC Plus, active low, RTC-capable (deep sleep wake)
-define(GPIO_BTN_A, 37).

% How long the reading stays on screen before going back to deep sleep
-define(DISPLAY_TIMEOUT_MS, 3000).

% Samples per log record; the sleep timer aims to wake with this many
% pending, giving ~hourly harvests at the 5-minute cadence.
-define(HARVEST_BATCH, 12).
-define(NVS_NS, atomvm_yun).
-define(NVS_HARVEST_COUNT, harvest_count).

% Unix time below which the clock is clearly not SNTP-synchronized.
-define(PLAUSIBLE_TIME, 1600000000).

% Thermometer: the ULP sampler (yun_sampler) reads the SHT20 every 5
% minutes into a ring in RTC memory while everything sleeps. Roughly
% every hour a dark timer wake harvests the ring (plus a battery
% reading) into the flash log. A BtnA wake additionally shows the
% temperature big with a battery gauge.
start() ->
    Cause = esp:sleep_get_wakeup_cause(),
    io:format("wakeup cause: ~p\n", [Cause]),
    case Cause of
        sleep_wakeup_timer -> dark_wake();
        sleep_wakeup_ulp -> dark_wake();
        _ -> interactive_wake()
    end.

% Hourly harvest: no display, minimal time awake. Once a day (or until
% first success) the clock is SNTP-synchronized so log timestamps are
% absolute.
dark_wake() ->
    m5:begin_([{clear_display, false}]),
    m5_display:sleep(),
    Loaded = yun_sampler:ensure_loaded(),
    io:format("sampler: ~p, count: ~p\n", [Loaded, yun_sampler:sample_count()]),
    harvest_if_due(),
    maybe_sync_clock(),
    go_to_sleep().

maybe_sync_clock() ->
    case yun_net:provisioned() andalso yun_net:sync_due() of
        true ->
            case yun_net:up() of
                {ok, _Ip} ->
                    receive
                        sntp_synchronized ->
                            yun_net:mark_synced(),
                            io:format("clock synchronized: ~p\n", [
                                erlang:system_time(second)
                            ])
                    after 20000 ->
                        io:format("sntp sync timed out\n")
                    end,
                    yun_net:down();
                Error ->
                    io:format("wifi for sntp failed: ~p\n", [Error])
            end;
        false ->
            ok
    end.

interactive_wake() ->
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
    draw_ui(Reading, Battery),
    harvest_if_due(),

    % Serve the web app while the user is looking at the device; each
    % request extends the window, so a phone actively fetching keeps it
    % alive. Unprovisioned devices just show the reading.
    case yun_net:up() of
        {ok, {A, B, C, D}} ->
            Url = list_to_binary(
                io_lib:format("http://~s.local  ~B.~B.~B.~B", [yun_net:name(), A, B, C, D])
            ),
            io:format("serving at ~s\n", [Url]),
            m5_display:set_text_size(1),
            m5_display:draw_string(Url, 8, m5_display:height() - 12),
            BatteryByte =
                case Battery of
                    L when is_integer(L), L >= 0, L =< 100 -> L;
                    _ -> 16#FF
                end,
            yun_http:serve(BatteryByte, 90000),
            yun_net:down();
        {error, not_provisioned} ->
            timer:sleep(?DISPLAY_TIMEOUT_MS);
        {error, Error} ->
            io:format("wifi failed: ~p\n", [Error]),
            timer:sleep(?DISPLAY_TIMEOUT_MS)
    end,
    m5_display:sleep(),
    go_to_sleep().

go_to_sleep() ->
    % The ULP wakeup trigger keeps the FSM timer clocked through deep
    % sleep (and its memory considered in use); the pd override pins RTC
    % slow memory on as well. Timer runs never execute WAKE (only
    % wake_request ones do), so the trigger causes no spurious CPU
    % wakes. The button must use EXT1: on the ESP32, EXT0 cannot be
    % combined with the ULP wakeup source (this fails, and a crashed
    % main process ends in an unconfigured sleep that kills the
    % sampler). EXT1 mode 0 = wake when all masked pins are low.
    ok = esp:sleep_enable_ulp_wakeup(),
    ok = ulp:keep_memory_in_deep_sleep(),
    ok = esp:sleep_enable_ext1_wakeup(1 bsl ?GPIO_BTN_A, 0),
    esp:deep_sleep(ms_until_harvest()).

% Move complete batches from the sampler ring to the flash log. Runs on
% every wake; does nothing until a full batch is pending, so button
% presses between hourly wakes stay cheap.
harvest_if_due() ->
    Last = nvs_harvest_count(),
    {Count, Samples} = yun_sampler:harvest(Last),
    case length(Samples) >= ?HARVEST_BATCH of
        true ->
            Battery =
                case m5_power:get_battery_level() of
                    L when is_integer(L), L >= 0, L =< 100 -> L;
                    _ -> 16#FF
                end,
            Now = erlang:system_time(second),
            Ts =
                case Now >= ?PLAUSIBLE_TIME of
                    true -> Now;
                    false -> 0
                end,
            append_batches(Samples, Ts, Battery),
            esp:nvs_put_binary(?NVS_NS, ?NVS_HARVEST_COUNT, <<Count:16/little>>),
            io:format("harvested ~B samples (count ~B)\n", [length(Samples), Count]);
        false ->
            ok
    end.

% Oldest-first samples, chunked into records of up to ?HARVEST_BATCH;
% each record is stamped with the time of its newest sample, spaced by
% the 5-minute cadence.
append_batches([], _Ts, _Battery) ->
    ok;
append_batches(Samples, Ts, Battery) ->
    PeriodS = yun_sampler:sample_period_us() div 1000000,
    Total = length(Samples),
    case Total > ?HARVEST_BATCH of
        true ->
            {Chunk, Rest} = lists:split(?HARVEST_BATCH, Samples),
            ChunkTs =
                case Ts of
                    0 -> 0;
                    _ -> Ts - length(Rest) * PeriodS
                end,
            ok = yun_log:append(ChunkTs, Battery, Chunk),
            append_batches(Rest, Ts, Battery);
        false ->
            ok = yun_log:append(Ts, Battery, Samples)
    end.

nvs_harvest_count() ->
    case esp:nvs_get_binary(?NVS_NS, ?NVS_HARVEST_COUNT) of
        <<C:16/little>> -> C;
        _ -> 0
    end.

% Sleep until a full batch is pending (self-aligning to the sampler's
% cadence). The margin only covers the sample's own duration: the deep
% sleep timer and the ULP wake timer share the RTC slow clock, so their
% drift cancels.
ms_until_harvest() ->
    Pending = (yun_sampler:sample_count() - nvs_harvest_count()) band 16#FFFF,
    Missing = max(?HARVEST_BATCH - Pending, 0),
    PeriodMs = yun_sampler:sample_period_us() div 1000,
    max(Missing * PeriodMs + 3000, 60000).

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
