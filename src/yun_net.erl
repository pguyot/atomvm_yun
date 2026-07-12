%
% WiFi / SNTP / mDNS for the thermometer, all driven by NVS-provisioned
% settings (namespace atomvm_yun):
%   wifi_ssid, wifi_psk -- credentials (written by tools/provision.sh)
%   name                -- device name, doubles as the mDNS hostname
%                          (http://<name>.local); defaults to yun-XXXX
%                          from the STA MAC until set
%   last_sync           -- unix time of the last SNTP synchronization
%
-module(yun_net).

-export([
    up/0,
    down/0,
    provisioned/0,
    name/0,
    set_name/1,
    sync_due/0,
    mark_synced/0
]).

-define(NVS_NS, atomvm_yun).
-define(SYNC_INTERVAL_S, 86400).
-define(PLAUSIBLE_TIME, 1600000000).

%% @doc Bring WiFi up (STA), start SNTP and mDNS. Returns the IP.
%% The caller receives an {sntp_synchronized} message when time syncs.
-spec up() -> {ok, inet:ip4_address()} | {error, any()}.
up() ->
    case {esp:nvs_get_binary(?NVS_NS, wifi_ssid), esp:nvs_get_binary(?NVS_NS, wifi_psk)} of
        {Ssid, Psk} when is_binary(Ssid), is_binary(Psk), Ssid =/= <<>> ->
            Self = self(),
            Config = [
                % note: network:wait_for_sta/1,2 must NOT be used here --
                % it starts the network itself and would collide with
                % this explicit start; we wait on the got_ip callback.
                {sta, [
                    {ssid, Ssid},
                    {psk, Psk},
                    {got_ip, fun(IpInfo) -> Self ! {yun_got_ip, IpInfo} end}
                ]},
                {sntp, [
                    {host, "pool.ntp.org"},
                    {synchronized, fun(_TimeVal) -> Self ! sntp_synchronized end}
                ]},
                % both keys: network.erl's type says {host, _} but its
                % maybe_start_mdns reads `hostname` (bug, fixed upstream)
                {mdns, [{host, name()}, {hostname, name()}]}
            ],
            case network:start(Config) of
                {ok, _Pid} ->
                    receive
                        {yun_got_ip, {Address, _Netmask, _Gateway}} ->
                            {ok, Address}
                    after 30000 ->
                        network:stop(),
                        {error, association_timeout}
                    end;
                Error ->
                    Error
            end;
        _ ->
            {error, not_provisioned}
    end.

-spec down() -> ok | {error, any()}.
down() ->
    network:stop().

-spec provisioned() -> boolean().
provisioned() ->
    is_binary(esp:nvs_get_binary(?NVS_NS, wifi_ssid)).

-spec name() -> binary().
name() ->
    case esp:nvs_get_binary(?NVS_NS, name) of
        Name when is_binary(Name), Name =/= <<>> -> Name;
        _ -> default_name()
    end.

%% @doc Rename the device. Takes effect as mDNS hostname at the next
%% WiFi start. Names are sanitized to a DNS label: lowercase ASCII
%% letters, digits and dashes, max 32 chars.
-spec set_name(binary()) -> ok | {error, invalid_name}.
set_name(Name) when is_binary(Name) ->
    case sanitize(Name) of
        <<>> -> {error, invalid_name};
        Clean -> esp:nvs_put_binary(?NVS_NS, name, Clean)
    end.

sanitize(Name) ->
    Chars = [sanitize_char(C) || <<C>> <= Name],
    Kept = [C || C <- Chars, C =/= skip],
    list_to_binary(lists:sublist(Kept, 32)).

sanitize_char(C) when C >= $a, C =< $z -> C;
sanitize_char(C) when C >= $0, C =< $9 -> C;
sanitize_char(C) when C >= $A, C =< $Z -> C + 32;
sanitize_char($-) -> $-;
sanitize_char(_) -> skip.

default_name() ->
    <<_:32, B5:8, B6:8>> = esp:get_mac(wifi_sta),
    list_to_binary(io_lib:format("yun-~2.16.0b~2.16.0b", [B5, B6])).

%% @doc True when the clock was never synchronized (or not for a day).
-spec sync_due() -> boolean().
sync_due() ->
    Now = erlang:system_time(second),
    case Now < ?PLAUSIBLE_TIME of
        true ->
            true;
        false ->
            case esp:nvs_get_binary(?NVS_NS, last_sync) of
                <<Last:32/little>> -> Now - Last > ?SYNC_INTERVAL_S;
                _ -> true
            end
    end.

-spec mark_synced() -> ok.
mark_synced() ->
    Now = erlang:system_time(second),
    esp:nvs_put_binary(?NVS_NS, last_sync, <<Now:32/little>>).
