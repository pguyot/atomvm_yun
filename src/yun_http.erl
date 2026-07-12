%
% Minimal HTTP server for the thermometer web app. Serves until no
% request arrives for the inactivity window, then returns so the caller
% can go back to deep sleep. Single-threaded on purpose: one phone, tiny
% pages, and the process mailbox stays available for the SNTP
% synchronization message (checked between requests).
%
% Routes:
%   GET  /           the single-file SPA (priv/index.html)
%   GET  /data.json  name, clock, battery, current reading, log records
%   POST /name       rename the device (takes effect at next WiFi start)
%
-module(yun_http).

-export([serve/3]).

-define(MAX_RECORDS, 168).

%% @doc Listen on port 80 and serve requests; returns after
%% InactivityMs without one. Battery is displayed data (measured once
%% by the caller; it doesn't change meaningfully while serving).
% Hard ceiling on a serve session, whatever the request pattern: the
% battery must win over a tab left polling in someone's pocket.
-define(MAX_SERVE_MS, 600000).
% Accept in short slices so the tick callback (button poll, display
% timeout) runs regularly while serving.
-define(SLICE_MS, 300).

%% @doc Serve until InactivityMs pass without a request (a button press
%% via the tick callback also counts as activity). Tick is called every
%% ~?SLICE_MS and returns pressed | idle.
-spec serve(Battery :: 0..255, InactivityMs :: pos_integer(), Tick :: fun(() -> pressed | idle)) ->
    ok.
serve(Battery, InactivityMs, Tick) ->
    case gen_tcp:listen(80, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSock} ->
            io:format("http listening on 80\n"),
            Html = atomvm:read_priv(atomvm_yun, "index.html"),
            Now = erlang:monotonic_time(millisecond),
            accept_loop(
                ListenSock, Html, Battery, InactivityMs, Tick, Now, Now + ?MAX_SERVE_MS
            ),
            gen_tcp:close(ListenSock),
            ok;
        {error, Reason} ->
            io:format("http listen failed: ~p\n", [Reason]),
            ok
    end.

accept_loop(ListenSock, Html, Battery, InactivityMs, Tick, LastActivity, Deadline) ->
    drain_sntp(),
    Now = erlang:monotonic_time(millisecond),
    case Now >= Deadline orelse Now - LastActivity >= InactivityMs of
        true ->
            ok;
        false ->
            LastActivity1 =
                case Tick() of
                    pressed -> Now;
                    idle -> LastActivity
                end,
            case gen_tcp:accept(ListenSock, ?SLICE_MS) of
                {ok, Sock} ->
                    _ = handle(Sock, Html, Battery),
                    gen_tcp:close(Sock),
                    accept_loop(
                        ListenSock,
                        Html,
                        Battery,
                        InactivityMs,
                        Tick,
                        erlang:monotonic_time(millisecond),
                        Deadline
                    );
                {error, timeout} ->
                    accept_loop(
                        ListenSock, Html, Battery, InactivityMs, Tick, LastActivity1, Deadline
                    );
                {error, Reason} ->
                    io:format("http accept failed: ~p\n", [Reason]),
                    ok
            end
    end.

% The SNTP synchronized callback sends to the process that started the
% network -- which is the one serving here.
drain_sntp() ->
    receive
        sntp_synchronized ->
            yun_net:mark_synced(),
            io:format("clock synchronized: ~p\n", [erlang:system_time(second)])
    after 0 ->
        ok
    end.

handle(Sock, Html, Battery) ->
    case gen_tcp:recv(Sock, 0, 5000) of
        {ok, Request} ->
            route(Sock, Request, Html, Battery);
        {error, _} ->
            ok
    end.

route(Sock, <<"GET / ", _/binary>>, Html, _Battery) ->
    reply(Sock, <<"200 OK">>, <<"text/html">>, Html);
route(Sock, <<"GET /data.json", _/binary>>, _Html, Battery) ->
    reply(Sock, <<"200 OK">>, <<"application/json">>, data_json(Battery));
route(Sock, <<"POST /name", _/binary>> = Request, _Html, _Battery) ->
    Body = body_of(Request),
    case yun_net:set_name(Body) of
        ok ->
            reply(Sock, <<"200 OK">>, <<"application/json">>, [
                <<"{\"name\":\"">>, yun_net:name(), <<"\"}">>
            ]);
        {error, invalid_name} ->
            reply(Sock, <<"400 Bad Request">>, <<"text/plain">>, <<"invalid name">>)
    end;
route(Sock, _Other, _Html, _Battery) ->
    reply(Sock, <<"404 Not Found">>, <<"text/plain">>, <<"not found">>).

body_of(Request) ->
    case binary:split(Request, <<"\r\n\r\n">>) of
        [_Headers, Body] -> Body;
        _ -> <<>>
    end.

reply(Sock, Status, ContentType, Body) ->
    Length = integer_to_binary(iolist_size(Body)),
    send_chunked(
        Sock,
        iolist_to_binary([
            <<"HTTP/1.1 ">>,
            Status,
            <<"\r\nContent-Type: ">>,
            ContentType,
            <<"\r\nContent-Length: ">>,
            Length,
            <<"\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n">>,
            Body
        ])
    ).

% lwip's TCP send buffer is ~5.7 KB and AtomVM's socket layer reports
% buffer-full as an error instead of retrying (AtomVM PR #2345 fixes
% this upstream). Send MSS-sized chunks with a pause every few to let
% the buffer drain, and retry a chunk once on a transient error.
-define(CHUNK, 1400).
-define(CHUNKS_PER_PAUSE, 3).

send_chunked(Sock, Bin) ->
    send_chunked(Sock, Bin, 0).

send_chunked(_Sock, <<>>, _N) ->
    ok;
send_chunked(Sock, Bin, N) when N rem ?CHUNKS_PER_PAUSE =:= 0, N > 0 ->
    timer:sleep(30),
    send_chunked(Sock, Bin, N + 1);
send_chunked(Sock, Bin, N) ->
    {Chunk, Rest} =
        case Bin of
            <<C:?CHUNK/binary, R/binary>> -> {C, R};
            _ -> {Bin, <<>>}
        end,
    case gen_tcp:send(Sock, Chunk) of
        ok ->
            send_chunked(Sock, Rest, N + 1);
        {error, Reason} ->
            io:format("send retry after: ~p\n", [Reason]),
            timer:sleep(80),
            case gen_tcp:send(Sock, Chunk) of
                ok -> send_chunked(Sock, Rest, N + 1);
                Error -> Error
            end
    end.

data_json(Battery) ->
    Current =
        case yun_sampler:latest() of
            {ok, Raw} -> integer_to_binary(yun_sampler:raw_to_millicelsius(Raw));
            {error, _} -> <<"null">>
        end,
    Records = yun_log:last_records(?MAX_RECORDS),
    [
        <<"{\"name\":\"">>,
        yun_net:name(),
        <<"\",\"now\":">>,
        integer_to_binary(erlang:system_time(second)),
        <<",\"period_s\":">>,
        integer_to_binary(yun_sampler:sample_period_us() div 1000000),
        <<",\"battery\":">>,
        battery_json(Battery),
        <<",\"charging\":">>,
        charging_json(Battery),
        <<",\"temp_mc\":">>,
        Current,
        <<",\"records\":[">>,
        lists:join(<<",">>, [record_json(R) || R <- Records]),
        <<"]}">>
    ].

record_json(#{timestamp := Ts, battery := B, samples := Samples}) ->
    [
        <<"{\"t\":">>,
        integer_to_binary(Ts),
        <<",\"b\":">>,
        battery_json(B),
        <<",\"c\":">>,
        charging_json(B),
        <<",\"s\":[">>,
        lists:join(<<",">>, [integer_to_binary(S) || S <- Samples]),
        <<"]}">>
    ].

% Battery byte: level in the low 7 bits, charging flag in bit 7,
% 16#FF = unknown.
battery_json(16#FF) -> <<"null">>;
battery_json(B) -> integer_to_binary(B band 16#7F).

charging_json(16#FF) -> <<"false">>;
charging_json(B) when B band 16#80 =/= 0 -> <<"true">>;
charging_json(_) -> <<"false">>.
