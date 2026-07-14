-module(atomvm_yun).

-export([start/0, test_yun_hat/0]).

% BtnA on the M5StickC Plus, active low, RTC-capable (deep sleep wake)
-define(GPIO_BTN_A, 37).

% Red LED, active low; nothing initializes it so it glows by default
-define(GPIO_LED, 10).

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
    try
        case Cause of
            sleep_wakeup_timer -> dark_wake();
            sleep_wakeup_ulp -> dark_wake();
            _ -> interactive_wake()
        end
    catch
        Class:Reason:Stack ->
            % A field thermometer must never hot-boot-loop on an
            % exception (it blinks and drains the battery, and AtomVM's
            % crash reporter can itself double-fault). Log and deep-sleep
            % so a transient fault recovers on the next wake.
            io:format("FATAL ~p:~p\n~p\n", [Class, Reason, Stack]),
            safe_sleep()
    end.

% Minimal, exception-proof path to deep sleep: keep the sampler alive,
% arm the button and a 1-minute retry timer, and sleep. Every step is
% guarded so nothing here can re-raise into a loop.
safe_sleep() ->
    catch esp:sleep_enable_ulp_wakeup(),
    catch ulp:keep_memory_in_deep_sleep(),
    catch esp:sleep_enable_ext1_wakeup(1 bsl ?GPIO_BTN_A, 0),
    esp:deep_sleep(60000).

% Hourly harvest: no display, minimal time awake. Once a day (or until
% first success) the clock is SNTP-synchronized so log timestamps are
% absolute.
dark_wake() ->
    m5:begin_([{clear_display, false}]),
    % After begin_ (which reconfigures GPIO10) so it takes effect.
    led_off(),
    display_off(),
    Loaded = ensure_sampler(),
    io:format("sampler: ~p, count: ~p\n", [Loaded, yun_sampler:sample_count()]),
    harvest_if_due(),
    maybe_sync_clock(),
    go_to_sleep().

% Load the sampler if needed; a fresh load resets the ULP sample_count
% to 0, so the NVS harvest cursor (which counts against it) must reset
% too, else the next harvest sees a huge wrapped delta and records a
% ring full of stale/zero samples.
ensure_sampler() ->
    case yun_sampler:ensure_loaded() of
        loaded ->
            esp:nvs_put_binary(?NVS_NS, ?NVS_HARVEST_COUNT, <<0:16/little>>),
            loaded;
        already_loaded ->
            already_loaded
    end.

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
    % After begin_ (which reconfigures GPIO10) so it takes effect.
    led_off(),
    % The previous wake may have been a dark one that put the panel to
    % sleep; begin_ alone does not always bring it back.
    m5_display:wakeup(),
    m5_display:set_epd_mode(fastest),
    m5_display:set_brightness(128),

    case m5_display:width() < m5_display:height() of
        true ->
            % Landscape mode
            m5_display:set_rotation(m5_display:get_rotation() bxor 1);
        false ->
            ok
    end,

    Loaded = ensure_sampler(),
    io:format("sampler: ~p, count: ~p\n", [Loaded, yun_sampler:sample_count()]),

    % First contact fenced from the ULP sampler; also logs which hat
    % firmware is mounted.
    ok = yun_sampler:acquire_bus(),
    ok = yun_hat:open(),
    io:format("hat firmware: ~p\n", [yun_hat:version()]),
    ok = yun_sampler:release_bus(),

    Battery = m5_power:get_battery_level(),
    % Show the newest VALID sample from the ULP ring (a few minutes old
    % at worst), so a single failed deep-sleep sample doesn't surface as
    % a sensor error. Only an entirely empty/failed ring (cold boot)
    % forces a fresh sample.
    Reading =
        case yun_sampler:latest_valid() of
            {ok, _} = Ok -> Ok;
            {error, no_valid_sample} -> yun_sampler:sample_now(3000)
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
            % Start on the temperature screen. Drive the carousel from a
            % falling-edge GPIO interrupt on BtnA (active low) rather than
            % polling -- polling in the 300 ms serve loop missed presses.
            put(screen, 0),
            put(last_btn, 0),
            GPIO = gpio:start(),
            gpio:set_direction(GPIO, ?GPIO_BTN_A, input),
            gpio:set_int(GPIO, ?GPIO_BTN_A, falling),
            put(display_off_at, erlang:monotonic_time(millisecond) + 15000),
            yun_http:serve(battery_byte(), 90000, fun(Ev) -> serve_event(Ev, Reading, Url) end),
            gpio:remove_int(GPIO, ?GPIO_BTN_A),
            yun_net:down();
        {error, not_provisioned} ->
            timer:sleep(?DISPLAY_TIMEOUT_MS);
        {error, Error} ->
            io:format("wifi failed: ~p\n", [Error]),
            timer:sleep(?DISPLAY_TIMEOUT_MS)
    end,
    display_off(),
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
            Battery = battery_byte(),
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

% Battery level (0..100) in the low 7 bits, charging flag in bit 7;
% 16#FF = unknown. Charging matters to the log because the charger
% warms the board and skews the SHT20 readings.
battery_byte() ->
    Level =
        case m5_power:get_battery_level() of
            L when is_integer(L), L >= 0, L =< 100 -> L;
            _ -> undefined
        end,
    case Level of
        undefined ->
            16#FF;
        _ ->
            case m5_power:is_charging() of
                is_charging -> Level bor 16#80;
                _ -> Level
            end
    end.

% Serve-loop event handler. `{button, _}` fires on a BtnA GPIO
% interrupt and advances the 3-screen carousel (temperature -> 24 h
% temperature graph -> battery graph -> back); `tick` fires on the
% loop's idle timeout and only manages the display-off timer. A button
% press also relights the display, which sleeps 15 s later.
serve_event({button, _Pin}, Reading0, Url) ->
    Now = erlang:monotonic_time(millisecond),
    % Debounce: a mechanical press can fire several falling edges.
    case Now - get(last_btn) >= 250 of
        true ->
            put(last_btn, Now),
            Screen = (get(screen) + 1) rem 3,
            put(screen, Screen),
            m5_display:wakeup(),
            m5_display:set_brightness(128),
            draw_screen(Screen, Reading0, Url),
            put(display_off_at, Now + 15000),
            activity;
        false ->
            idle
    end;
serve_event(tick, _Reading0, _Url) ->
    case get(display_off_at) of
        undefined ->
            ok;
        OffAt ->
            case erlang:monotonic_time(millisecond) >= OffAt of
                true ->
                    display_off(),
                    put(display_off_at, undefined);
                false ->
                    ok
            end
    end,
    idle.

% Screen 0: current temperature. 1: last-24 h temperature graph.
% 2: battery-level graph.
draw_screen(0, Reading0, Url) ->
    Reading =
        case yun_sampler:latest_valid() of
            {ok, _} = Ok -> Ok;
            _ -> Reading0
        end,
    draw_ui(Reading, m5_power:get_battery_level()),
    m5_display:set_text_size(1),
    m5_display:draw_string(Url, 8, m5_display:height() - 12);
draw_screen(1, _Reading0, _Url) ->
    draw_temp_graph();
draw_screen(2, _Reading0, _Url) ->
    draw_batt_graph().

% Panel sleep alone leaves the AXP192-driven backlight lit on the
% StickC Plus; cut the brightness too or the screen stays visibly on.
display_off() ->
    m5_display:set_brightness(0),
    m5_display:sleep().

% The red LED (active low) is not an indicator of anything -- drive it
% off. NOT held through deep sleep: gpio:deep_sleep_hold_en() freezes
% pad state globally, which traps the SDA/SCL lines the ULP sampler
% drives during deep sleep (arbitration lost -> sensor errors).
led_off() ->
    gpio:set_pin_mode(?GPIO_LED, output),
    gpio:digital_write(?GPIO_LED, high).

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

-define(COL_GRID, 16#404040).
-define(COL_TEMP, 16#00E5FF).
-define(COL_BATT, 16#00C853).
-define(COL_TXT, 16#FFFFFF).

% Temperature samples (tenths of a degree), oldest first, for roughly the
% last 24 h: harvested history from the flash log plus the not-yet-
% harvested tail still in the ULP ring. Error/empty samples are dropped.
temp_series() ->
    Records = yun_log:last_records(24),
    FlashRaw = lists:append([maps:get(samples, R) || R <- Records]),
    {_, RingRaw} = yun_sampler:harvest(nvs_harvest_count()),
    Tenths = [
        (yun_sampler:raw_to_millicelsius(S) + 50) div 100
     || S <- FlashRaw ++ RingRaw, S > 0, S < 16#FFF0
    ],
    last_n(Tenths, 288).

% Battery percentage, oldest first, one point per hourly record plus the
% current level as the newest point.
batt_series() ->
    Records = yun_log:last_records(24),
    Hist = [
        maps:get(battery, R) band 16#7F
     || R <- Records, maps:get(battery, R) =/= 16#FF
    ],
    Now =
        case m5_power:get_battery_level() of
            L when is_integer(L), L >= 0, L =< 100 -> [L];
            _ -> []
        end,
    last_n(Hist ++ Now, 96).

last_n(L, N) ->
    lists:nthtail(max(0, length(L) - N), L).

draw_temp_graph() ->
    case temp_series() of
        Vals when length(Vals) >= 2 ->
            Lo = lists:min(Vals),
            Hi = lists:max(Vals),
            % pad by ~0.5 C and guarantee a non-zero range
            Pad = max(5, (Hi - Lo) div 8),
            draw_graph(
                <<"Temp / 24h">>,
                Vals,
                Lo - Pad,
                Hi + Pad,
                fun tenths_label/1,
                ?COL_TEMP
            );
        _ ->
            draw_collecting(<<"Temp / 24h">>)
    end.

draw_batt_graph() ->
    case batt_series() of
        Vals when length(Vals) >= 2 ->
            draw_graph(<<"Battery / 24h">>, Vals, 0, 100, fun pct_label/1, ?COL_BATT);
        _ ->
            draw_collecting(<<"Battery / 24h">>)
    end.

tenths_label(T) -> list_to_binary(io_lib:format("~B.~B", [T div 10, abs(T rem 10)])).
pct_label(P) -> list_to_binary(io_lib:format("~B", [P])).

% Line graph of Vals (oldest->newest, evenly spaced on X) with a value
% axis from Min to Max. LabelFun formats the Y bounds.
draw_graph(Title, Vals, Min, Max, LabelFun, Color) ->
    W = m5_display:width(),
    H = m5_display:height(),
    L = 34,
    R = W - 6,
    T = 20,
    B = H - 14,
    Range = max(1, Max - Min),
    N = length(Vals),
    m5_display:start_write(),
    m5_display:fill_screen(16#000000),
    m5_display:set_text_size(1),
    m5_display:draw_string(Title, 6, 4),
    % axes
    m5_display:draw_fast_hline(L, B, R - L, ?COL_GRID),
    m5_display:draw_fast_vline(L, T, B - T, ?COL_GRID),
    % Y bounds
    m5_display:draw_string(LabelFun(Max), 2, T - 3),
    m5_display:draw_string(LabelFun(Min), 2, B - 6),
    % X range
    m5_display:draw_string(<<"-24h">>, L, B + 3),
    m5_display:draw_string(<<"now">>, R - 18, B + 3),
    X = fun(I) -> L + (R - L) * I div (N - 1) end,
    Y = fun(V) -> B - (B - T) * (V - Min) div Range end,
    draw_polyline(Vals, X, Y, Color, 0),
    m5_display:end_write().

draw_polyline([_], _X, _Y, _Color, _I) ->
    ok;
draw_polyline([V1, V2 | Rest], X, Y, Color, I) ->
    m5_display:draw_line(X(I), Y(V1), X(I + 1), Y(V2), Color),
    draw_polyline([V2 | Rest], X, Y, Color, I + 1).

draw_collecting(Title) ->
    m5_display:start_write(),
    m5_display:fill_screen(16#000000),
    m5_display:set_text_size(1),
    m5_display:draw_string(Title, 6, 4),
    m5_display:set_text_size(2),
    m5_display:draw_string(<<"collecting...">>, 20, m5_display:height() div 2 - 8),
    m5_display:end_write().

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
