-module(tiger_kv_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
    application:start(sasl),
    application:start(erlang_js),
    application:start(cowboy),
    application:start(tiger_core),
    cowboy:start_listener(bert,100,cowboy_tcp_transport,[{port,11211}],memcached_frontend,[])
%%    tiger_kv_sup:start_link()
.

stop(_State) ->
    ok.
