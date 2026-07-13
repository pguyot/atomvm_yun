%
% Autonomous SHT20 sampler running on the ESP32 ULP coprocessor.
%
% The ULP wakes on its own timer every ?SAMPLE_PERIOD_US, bit-bangs the
% SHT20 on the hat I2C bus (SDA G0, SCL G26) and appends the raw 16-bit
% temperature to a ring buffer in RTC slow memory -- all without waking
% the main CPU. The program and its data survive deep sleep and EN-pin
% resets (RTC domain), so it is loaded only on cold boots (magic check).
%
% Host protocol (words in ULP RTC memory, offsets = ?OFF_* below):
% - host_busy: set to 1 by the host while it talks I2C to the hat STM32;
%   the ULP skips its sample instead of colliding with the transaction.
% - wake_request: set to 1 before triggering a run to get the {ulp, Ref}
%   ISR message when the sample lands (sample_now/1); timer-driven runs
%   leave it 0 and never wake the CPU.
% - sample_count: free-running; the host remembers the count at its last
%   harvest and reads the delta out of the ring.
%
% Failed reads store sentinels >= 16#FFF0 (NACK/arbitration codes);
% harvest/1 keeps them (gaps in the log), sample_now/1 maps them to
% {error, Code}.
%
-module(yun_sampler).

-export([
    ensure_loaded/0,
    sample_now/1,
    latest/0,
    latest_valid/0,
    harvest/1,
    sample_count/0,
    acquire_bus/0,
    release_bus/0,
    sample_period_us/0,
    raw_to_millicelsius/1
]).

-include_lib("atomvm_ulp/include/ulp.hrl").

-define(GPIO_SHT20_I2C_SCL, 26).
-define(GPIO_SHT20_I2C_SDA, 0).
-define(RTC_GPIO_SHT20_I2C_SCL, 7).
-define(RTC_GPIO_SHT20_I2C_SDA, 11).

% 5 minutes, on ULP wakeup period slot 0
-define(SAMPLE_PERIOD_US, 300000000).

% Data block word offsets; must match the label order in program/0.
-define(OFF_MAGIC, 0).
-define(OFF_WRITE_INDEX, 1).
-define(OFF_SAMPLE_COUNT, 2).
-define(OFF_HOST_BUSY, 3).
-define(OFF_WAKE_REQUEST, 4).
-define(OFF_LAST_SAMPLE, 5).
-define(OFF_RING, 6).

-define(RING_SIZE, 64).
-define(RING_MASK, (?RING_SIZE - 1)).

% "YU" + layout revision; bump when the program or layout changes so a
% stale resident program is replaced at the next cold boot.
-define(MAGIC, 16#59550005).

% Error sentinels (must stay >= 16#FFF0)
-define(ERR_ADDR_W_NACK, 16#FFFE).
-define(ERR_CMD_NACK, 16#FFFD).
-define(ERR_ADDR_R_NACK, 16#FFFC).
-define(ERR_ARBITRATION, 16#FFFF).

-spec sample_period_us() -> pos_integer().
sample_period_us() -> ?SAMPLE_PERIOD_US.

%% @doc Make sure the sampler is resident and its timer running. On a
%% warm boot (magic word present) the resident program keeps running
%% untouched -- reloading would wipe the ring. Returns the entry point
%% either way.
-spec ensure_loaded() -> loaded | already_loaded.
ensure_loaded() ->
    case ulp:read_memory(?OFF_MAGIC) of
        ?MAGIC ->
            already_loaded;
        _ ->
            init_rtc_pins(),
            {Binary, Labels} = program(),
            ulp:load_binary(Binary),
            ok = ulp:set_wakeup_period(0, ?SAMPLE_PERIOD_US),
            ulp:run(maps:get(entry, Labels)),
            loaded
    end.

%% @doc Trigger an immediate sample and wait for it (bounded by TimeoutMs).
%% Works by shortening the ULP wakeup period so the resident program runs
%% right away, then restoring the 5-minute period. The sample also lands
%% in the ring like any other.
-spec sample_now(TimeoutMs :: pos_integer()) ->
    {ok, Raw :: non_neg_integer()} | {error, any()}.
sample_now(TimeoutMs) ->
    {ok, {Handler, Ref}} = ulp:isr_register(),
    ulp:write_memory(?OFF_WAKE_REQUEST, 1),
    % Short enough to feel immediate, long enough to stay above the
    % ~100 ms run time so runs don't pile up back to back.
    ok = ulp:set_wakeup_period(0, 150000),
    Result =
        receive
            {ulp, Ref} -> latest()
        after TimeoutMs ->
            {error, timeout}
        end,
    ok = ulp:set_wakeup_period(0, ?SAMPLE_PERIOD_US),
    ulp:write_memory(?OFF_WAKE_REQUEST, 0),
    true = ulp:isr_deregister(Handler),
    Result.

%% @doc Latest sample (may be up to one period old).
-spec latest() -> {ok, Raw :: non_neg_integer()} | {error, any()}.
latest() ->
    case ulp:read_memory(?OFF_LAST_SAMPLE) band 16#FFFF of
        Err when Err >= 16#FFF0 -> {error, Err};
        0 -> {error, no_sample_yet};
        Raw -> {ok, Raw}
    end.

%% @doc Newest valid sample in the ring, scanning back from the write
%% pointer past any failed (>= 16#FFF0) or empty (0) slots. A thermometer
%% reading a few minutes old is fine; a single failed deep-sleep sample
%% should never surface as an error when good history is one slot back.
-spec latest_valid() -> {ok, Raw :: non_neg_integer()} | {error, no_valid_sample}.
latest_valid() ->
    WI = ulp:read_memory(?OFF_WRITE_INDEX) band ?RING_MASK,
    latest_valid(WI, ?RING_SIZE).

latest_valid(_WI, 0) ->
    {error, no_valid_sample};
latest_valid(WI, N) ->
    Idx = (WI - 1) band ?RING_MASK,
    case ulp:read_memory(?OFF_RING + Idx) band 16#FFFF of
        Raw when Raw > 0, Raw < 16#FFF0 -> {ok, Raw};
        _ -> latest_valid(Idx, N - 1)
    end.

%% ULP ST stores the program counter in the word's upper bits, so every
%% ULP-written word is only meaningful in its low 16 bits. The count
%% therefore wraps at 65536; keep harvest deltas in 16-bit arithmetic.
-spec sample_count() -> non_neg_integer().
sample_count() ->
    ulp:read_memory(?OFF_SAMPLE_COUNT) band 16#FFFF.

%% @doc Samples accumulated since a previous harvest (by its count),
%% oldest first. Returns {NewCount, Samples}; error sentinels are kept so
%% the log records gaps. If more than ?RING_SIZE samples passed, only the
%% newest ?RING_SIZE survive (the rest were overwritten).
-spec harvest(SinceCount :: non_neg_integer()) ->
    {non_neg_integer(), [non_neg_integer()]}.
harvest(SinceCount) ->
    Count = sample_count(),
    N0 = (Count - SinceCount) band 16#FFFF,
    N = min(N0, ?RING_SIZE),
    WI = ulp:read_memory(?OFF_WRITE_INDEX) band ?RING_MASK,
    Samples = [
        ulp:read_memory(?OFF_RING + ((WI - N + J) band ?RING_MASK)) band 16#FFFF
     || J <- lists:seq(0, N - 1)
    ],
    {Count, Samples}.

%% @doc Take the hat I2C bus for the host (yun_hat calls). Three steps:
%% the busy word makes future ULP runs skip their sample; the 150 ms
%% settle waits out an in-flight run (~100 ms incl. the SHT20 clock
%% stretch, which cannot be aborted); and the pads are routed back from
%% the RTC mux to the digital IO_MUX -- while a pad is RTC-routed the
%% hardware I2C peripheral cannot drive it.
-spec acquire_bus() -> ok.
acquire_bus() ->
    ulp:write_memory(?OFF_HOST_BUSY, 1),
    timer:sleep(150),
    rtc_gpio:deinit(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:deinit(?GPIO_SHT20_I2C_SCL),
    ok.

%% @doc Give the bus back to the ULP sampler (re-route the pads to the
%% RTC mux). Must be called before deep sleep or the sampler reads a
%% dead bus.
-spec release_bus() -> ok.
release_bus() ->
    init_rtc_pins(),
    ulp:write_memory(?OFF_HOST_BUSY, 0),
    ok.

%% @doc SHT20: T[mC] = -46850 + 175720 * S / 2^16 (status bits cleared).
-spec raw_to_millicelsius(non_neg_integer()) -> integer().
raw_to_millicelsius(Raw) ->
    -46850 + (175720 * (Raw band 16#FFFC)) div 65536.

init_rtc_pins() ->
    ?RTC_GPIO_SHT20_I2C_SCL = rtc_gpio:gpio_to_rtc_gpio(?GPIO_SHT20_I2C_SCL),
    ?RTC_GPIO_SHT20_I2C_SDA = rtc_gpio:gpio_to_rtc_gpio(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:init(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:set_direction(?GPIO_SHT20_I2C_SCL, input_output),
    rtc_gpio:pulldown_dis(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:pullup_en(?GPIO_SHT20_I2C_SCL),
    rtc_gpio:init(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:set_direction(?GPIO_SHT20_I2C_SDA, input_output),
    rtc_gpio:pulldown_dis(?GPIO_SHT20_I2C_SDA),
    rtc_gpio:pullup_en(?GPIO_SHT20_I2C_SDA),
    ok.

%
% The ULP program. Data block first (fixed offsets, see ?OFF_*), then
% code. The I2C bit-bang subroutines follow the SHT20 protocol with
% clock stretching support (the sensor holds SCL for up to ~85 ms during
% a hold-master measurement).
%
program() ->
    ulp:compile([
        % ---- data block ----
        <<?MAGIC:32/little>>,
        % write_index
        <<0:32>>,
        % sample_count
        <<0:32>>,
        % host_busy
        <<0:32>>,
        % wake_request
        <<0:32>>,
        % last_sample
        <<0:32>>,
        {label, ring}
    ] ++ [<<0:32>> || _ <- lists:seq(1, ?RING_SIZE)] ++ [
        % ---- code ----
        {label, entry},
        % skip the sample entirely while the host owns the bus
        ?I_MOVI(2, ?OFF_HOST_BUSY),
        ?I_LD(0, 2, 0),
        {jumpr_lt, do_sample, 1},
        ?I_HALT,

        {label, do_sample},
        {movi, 2, next0},
        {bxi, i2c_start},
        {label, next0},

        % Address 0x40, write
        ?I_MOVI(1, 2#10000000),
        {movi, 2, next1},
        {bxi, write_byte},
        {label, next1},
        ?I_JUMPR_LT(3, 1),
        ?I_MOVI(1, ?ERR_ADDR_W_NACK),
        {bxi, error_x},

        % Trigger T measurement, hold master (0xE3)
        ?I_MOVI(1, 2#11100011),
        {movi, 2, next2},
        {bxi, write_byte},
        {label, next2},
        ?I_JUMPR_LT(3, 1),
        ?I_MOVI(1, ?ERR_CMD_NACK),
        {bxi, error_x},

        {movi, 2, next3},
        {bxi, i2c_stop},
        {label, next3},

        {movi, 2, next4},
        {bxi, i2c_start},
        {label, next4},

        % Address 0x40, read
        ?I_MOVI(1, 2#10000001),
        {movi, 2, next5},
        {bxi, write_byte},
        {label, next5},
        ?I_JUMPR_LT(3, 1),
        ?I_MOVI(1, ?ERR_ADDR_R_NACK),
        {bxi, error_x},

        % Read the two data bytes; ACK the first, NACK the second (the
        % SHT20 allows terminating without the CRC byte). R1 accumulates
        % the 16-bit value across both calls.
        ?I_MOVI(1, 0),
        ?I_MOVI(3, 0),
        {movi, 2, next6},
        {bxi, read_byte},
        {label, next6},
        ?I_MOVI(3, 1),
        {movi, 2, next7},
        {bxi, read_byte},
        {label, next7},

        {movi, 2, next8},
        {bxi, i2c_stop},
        {label, next8},

        {bxi, store_result},

        % Errors land here with the sentinel in R1; release the bus
        % before recording (a stuck transaction must not hold SDA/SCL:
        % SDA is the ESP32's strapping pin).
        {label, arbitration_lost},
        ?I_MOVI(1, ?ERR_ARBITRATION),
        {label, error_x},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),

        % ---- store R1, advance the ring, count, maybe wake ----
        {label, store_result},
        ?I_MOVI(2, ?OFF_LAST_SAMPLE),
        ?I_ST(1, 2, 0),
        % ring[write_index] = R1
        ?I_MOVI(3, ?OFF_RING),
        ?I_MOVI(2, ?OFF_WRITE_INDEX),
        ?I_LD(0, 2, 0),
        ?I_ADDR(3, 3, 0),
        ?I_ST(1, 3, 0),
        % write_index = (write_index + 1) band MASK
        ?I_ADDI(0, 0, 1),
        ?I_ANDI(0, 0, ?RING_MASK),
        ?I_ST(0, 2, 0),
        % sample_count++
        ?I_MOVI(2, ?OFF_SAMPLE_COUNT),
        ?I_LD(0, 2, 0),
        ?I_ADDI(0, 0, 1),
        ?I_ST(0, 2, 0),
        % wake the CPU only when it asked for this sample
        ?I_MOVI(2, ?OFF_WAKE_REQUEST),
        ?I_LD(0, 2, 0),
        {jumpr_lt, finish, 1},
        ?I_MOVI(0, 0),
        ?I_ST(0, 2, 0),
        ?I_WAKE,
        {label, finish},
        ?I_HALT,

        % I2C Start
        % Returns to address set by R2.
        % On exit, SCL and SDA are driven low
        {label, i2c_start},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_WR_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        ?I_WR_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        ?I_BXR(2),

        % I2C Stop
        % Returns to address set by R2.
        {label, i2c_stop},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, i2c_stop_exit, 1},
        {bxi, arbitration_lost},
        {label, i2c_stop_exit},
        ?I_BXR(2),

        % Write a byte
        % Returns to address set by R2.
        % Byte to write is in R1
        % Stage counter and R0 are modified
        % On exit, SCL is driven low; R3 = ACK bit read back (0 = ACK)
        {label, write_byte},
        ?I_STAGE_RST,

        {label, write_byte_loop},
        ?I_ANDI(0, 1, 16#80),
        ?I_STAGE_INC(1),
        ?I_LSHI(1, 1, 1),

        {jumpr_ge, write_bit_high, 1},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        {bxi, write_byte_loop_continue},

        {label, write_bit_high},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, write_byte_loop_continue, 1},
        {bxi, arbitration_lost},

        {label, write_byte_loop_continue},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        {jumps_lt, write_byte_loop, 8},

        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        ?I_MOVR(3, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        ?I_BXR(2),

        % Read a byte
        % R3 determines if it's ACK or NACK
        % Byte accumulates into R1 (shift before OR, so the last bit is
        % not over-shifted; R1 carries across calls for 16-bit values)
        % R0 is used
        % Return address is R2.
        {label, read_byte},
        ?I_STAGE_RST,
        {label, read_byte_loop},
        ?I_LSHI(1, 1, 1),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        ?I_ORR(1, 1, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        ?I_STAGE_INC(1),
        {jumps_lt, read_byte_loop, 8},

        % Write ACK or NACK (R3)
        ?I_MOVR(0, 3),
        {jumpr_ge, read_byte_nack, 1},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 1),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        {bxi, read_byte_exit},

        {label, read_byte_nack},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SDA, 0),
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 0),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SCL),
        ?I_BL(-1, 1),
        ?I_RD_RTC_GPIO(?RTC_GPIO_SHT20_I2C_SDA),
        {jumpr_ge, read_byte_exit, 1},
        {bxi, arbitration_lost},

        {label, read_byte_exit},
        ?I_WR_RTC_GPIO_ENABLE(?RTC_GPIO_SHT20_I2C_SCL, 1),
        ?I_BXR(2)
    ]).
