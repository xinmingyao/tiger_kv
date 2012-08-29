-module(tiger_kv_app).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================

start(_StartType, _StartArgs) ->
   
						%    {ok,RedisIp}=tiger_kv_util:get_env(redis_ip,"127.0.0.1"),
        
    tiger_kv_sup:start_link()
    
.

stop(_State) ->
    ok.
