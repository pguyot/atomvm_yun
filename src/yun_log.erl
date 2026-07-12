%
% Append-only measurement log on the dedicated "thermolog" flash
% partition (704 KB).
%
% The log is a sequence of 32-byte records:
%
%   <<16#A5, Version:8, Battery:8, N:8, Timestamp:32/little,
%     S1:16/little, ..., S12:16/little>>
%
% Battery is 0..100 (16#FF when unknown), N is the number of valid
% samples (oldest first, remaining slots 0), Timestamp is the unix time
% of the LAST (newest) sample in the record -- 0 when the clock had not
% been SNTP-synchronized yet. Samples are raw SHT20 readings, 5 minutes
% apart; sentinel values >= 16#FFF0 mark failed reads.
%
% The write cursor lives in NVS (one write per record, ~hourly: no wear
% concern). Sectors are erased lazily when the cursor enters them, which
% also implements wrap-around after ~2.5 years.
%
-module(yun_log).

-export([
    append/3,
    last_records/1,
    cursor/0,
    record_size/0
]).

-define(PARTITION, <<"thermolog">>).
-define(PARTITION_SIZE, 16#B0000).
-define(RECORD_SIZE, 32).
-define(SECTOR_SIZE, 4096).
-define(REC_MAGIC, 16#A5).
-define(REC_VERSION, 1).
-define(SAMPLES_PER_RECORD, 12).

-define(NVS_NS, atomvm_yun).
-define(NVS_CURSOR, log_cursor).

-spec record_size() -> pos_integer().
record_size() -> ?RECORD_SIZE.

%% @doc Append one record. Samples beyond 12 are dropped (callers chunk).
-spec append(
    Timestamp :: non_neg_integer(),
    Battery :: 0..255,
    Samples :: [non_neg_integer()]
) -> ok | error.
append(Timestamp, Battery, Samples) when length(Samples) =< ?SAMPLES_PER_RECORD ->
    Cursor = cursor(),
    ok = maybe_erase_sector(Cursor),
    N = length(Samples),
    Padded = Samples ++ lists:duplicate(?SAMPLES_PER_RECORD - N, 0),
    SamplesBin = <<<<S:16/little>> || S <- Padded>>,
    Record = <<?REC_MAGIC, ?REC_VERSION, Battery, N, Timestamp:32/little, SamplesBin/binary>>,
    case esp:partition_write(?PARTITION, Cursor, Record) of
        ok ->
            Next = (Cursor + ?RECORD_SIZE) rem ?PARTITION_SIZE,
            esp:nvs_put_binary(?NVS_NS, ?NVS_CURSOR, <<Next:32/little>>),
            ok;
        error ->
            error
    end.

%% @doc The last Max records, oldest first, parsed to maps.
-spec last_records(Max :: pos_integer()) -> [map()].
last_records(Max) ->
    Cursor = cursor(),
    collect(Cursor, Max, []).

collect(_Cursor, 0, Acc) ->
    Acc;
collect(Cursor, Left, Acc) ->
    Pos = (Cursor - ?RECORD_SIZE + ?PARTITION_SIZE) rem ?PARTITION_SIZE,
    case esp:partition_read(?PARTITION, Pos, ?RECORD_SIZE) of
        {ok, <<?REC_MAGIC, ?REC_VERSION, Battery, N, Timestamp:32/little, SamplesBin/binary>>} when
            N =< ?SAMPLES_PER_RECORD
        ->
            Samples = [S || <<S:16/little>> <= SamplesBin],
            Record = #{
                timestamp => Timestamp,
                battery => Battery,
                samples => lists:sublist(Samples, N)
            },
            collect(Pos, Left - 1, [Record | Acc]);
        _ ->
            % free (erased) or corrupt slot: reached the beginning
            Acc
    end.

-spec cursor() -> non_neg_integer().
cursor() ->
    case esp:nvs_get_binary(?NVS_NS, ?NVS_CURSOR) of
        <<C:32/little>> when C < ?PARTITION_SIZE, C rem ?RECORD_SIZE =:= 0 ->
            C;
        _ ->
            0
    end.

% Erase the sector lazily when the cursor is at its first record. Also
% erases sector 0 on the very first append after provisioning (cursor 0).
maybe_erase_sector(Cursor) when Cursor rem ?SECTOR_SIZE =:= 0 ->
    esp:partition_erase_range(?PARTITION, Cursor, ?SECTOR_SIZE);
maybe_erase_sector(_Cursor) ->
    ok.
