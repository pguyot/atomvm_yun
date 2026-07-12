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

-export([serve/2]).

-define(MAX_RECORDS, 168).

%% @doc Listen on port 80 and serve requests; returns after
%% InactivityMs without one. Battery is displayed data (measured once
%% by the caller; it doesn't change meaningfully while serving).
-spec serve(Battery :: 0..255, InactivityMs :: pos_integer()) -> ok.
serve(Battery, InactivityMs) ->
    case gen_tcp:listen(80, [binary, {active, false}, {reuseaddr, true}]) of
        {ok, ListenSock} ->
            Html = atomvm:read_priv(atomvm_yun, "index.html"),
            accept_loop(ListenSock, Html, Battery, InactivityMs),
            gen_tcp:close(ListenSock),
            ok;
        {error, Reason} ->
            io:format("http listen failed: ~p\n", [Reason]),
            ok
    end.

accept_loop(ListenSock, Html, Battery, InactivityMs) ->
    drain_sntp(),
    case gen_tcp:accept(ListenSock, InactivityMs) of
        {ok, Sock} ->
            _ = handle(Sock, Html, Battery),
            gen_tcp:close(Sock),
            accept_loop(ListenSock, Html, Battery, InactivityMs);
        {error, timeout} ->
            ok;
        {error, Reason} ->
            io:format("http accept failed: ~p\n", [Reason]),
            ok
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
    gen_tcp:send(Sock, [
        <<"HTTP/1.1 ">>,
        Status,
        <<"\r\nContent-Type: ">>,
        ContentType,
        <<"\r\nContent-Length: ">>,
        Length,
        <<"\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n">>,
        Body
    ]).

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
        integer_to_binary(Battery),
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
        integer_to_binary(B),
        <<",\"s\":[">>,
        lists:join(<<",">>, [integer_to_binary(S) || S <- Samples]),
        <<"]}">>
    ].
