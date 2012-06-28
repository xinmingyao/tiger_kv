-module(tiger_kv_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    {ok,MemIp}=tiger_kv_util:get_env(memcached_ip,"127.0.0.1"),
    {ok,MemPort}=tiger_kv_util:get_env(memcached_port,11211),
    {ok,RedisIp}=tiger_kv_util:get_env(redis_ip,"127.0.0.1"),
    {ok,RedisPort}=tiger_kv_util:get_env(redis_port,6379),
    cowboy:start_listener(memcached,100,cowboy_tcp_transport,[{ip,MemIp},{port,MemPort}],memcached_frontend,[]),
    cowboy:start_listener(redis,100,cowboy_tcp_transport,[{ip,RedisIp},{port,RedisPort}],edis_client,[]),
    tiger_kv_sup:start_link()
.

stop(_State) ->
    ok.
