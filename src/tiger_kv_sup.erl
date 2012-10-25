%% -------------------------------------------------------------------
%%
%% riak_core: Core Riak Application
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
-module(tiger_kv_sup).

-behaviour(supervisor).
%% API
-export([start_link/0]).
-compile([{parse_transform, lager_transform}]). 
%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD2(I, Type,Paras, Timeout), {I, {I, start_listener, Paras}, permanent, Timeout, Type, [I]}).
-define(CHILD2(I, Type,Paras), ?CHILD2(I, Type,Paras,5000)).
-define(CHILD(I, Type, Timeout), {I, {I, start_link, []}, permanent, Timeout, Type, [I]}).
-define(CHILD(I, Type), ?CHILD(I, Type, 5000)).
-define (IF (Bool, A, B), if Bool -> A; true -> B end).

-define(MEMCACHED_BUCKET,1).
-define(REDIS_BUCKET,2).



%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

-define(BACKEND,backend).

-define(PROPLIST_KEY_VALUE(KEY,LISTS,DEFAULT),
	case proplists:get_value(KEY,LISTS) of
	    undefined->
		getip_by_string(DEFAULT);
	    _->getip_by_string(proplists:get_value(KEY,LISTS))
	end
       ).


-define(PROPLIST_KEY_VALUE2(KEY,LISTS,DEFAULT),
	case proplists:get_value(KEY,LISTS) of
	    undefined->
		getip_by_string(DEFAULT);
	    _->proplists:get_value(KEY,LISTS)
	end
       ).

getip_by_string(Ip)->
    case re:run(Ip,"([0-9]+).([0-9]+).([0-9]+).([0-9]+)",[]) of
	{match,[_,{S1,E1},{S2,E2},{S3,E3},{S4,E4}]}->
	    {list_to_integer(string:substr(Ip,S1+1,E1)),
	     list_to_integer(string:substr(Ip,S2+1,E2)),
	     list_to_integer(string:substr(Ip,S3+1,E3)),
	     list_to_integer(string:substr(Ip,S4+1,E4))}
		;
	_->
	    lager:debug("ip is not corrrect format:~p,use 127.0.0.1",[Ip]), 
	    {127,0,0,1}
    end.
init([]) ->
    
    {ok,MasterNodes}= tiger_core_util:get_env(master_nodes,['m1@127.0.0.1','m2@127.0.0.1','m3@127.0.0.1']),
    M=[{enable,true},{port,11211},{ip,{127,0,0,1}},{db_dir,"/tmp/memcached"},{gc_by_zab_log_count,1000}],
    {ok,MemValues}=tiger_kv_util:get_env(memcached,M),
    case
	proplists:get_value(enable,MemValues) of 
	true->
	    MemPort= ?PROPLIST_KEY_VALUE2(port,MemValues,11211),
	    Ip= ?PROPLIST_KEY_VALUE(ip,MemValues,{127,0,0,1}),
	    {ok,_}=cowboy:start_listener(memcached,100,cowboy_tcp_transport,[{port,MemPort},{ip,Ip}],memcached_frontend,[]),
	    DbDir=proplists:get_value(db_dir,MemValues),
	    Mopts=case lists:keyfind(gc_by_zab_log_count,1,MemValues) of
		      false->
			  [{gc_by_zab_log_count,1000},{bucket,?MEMCACHED_BUCKET}];
		      V2->
			  [V2,{bucket,?MEMCACHED_BUCKET}]
		  end,
	    B1={mem_back_end,
		    {memcached_backend, start_link,
		     [MasterNodes,Mopts,DbDir]},
	     permanent, 5000, worker, [mem_back_end]},
	    put(?BACKEND,[B1])

	    ;
	_->
	    put(?BACKEND,[]),
	    do_nothing
    end,
		 
    Job1={{daily, {11, 10, pm}},
	 fun() -> edis_db:send_snapshot() end},
    Job2={{daily, {11, 50, pm}},
	 fun() -> edis_db:send_gc() end},
    R=[{enable,true},{port,6379},{ip,{127,0,0,1}},{snapshot,Job1},{gc,Job2},{conf,"/tmp/redis.conf"},{db_dir,"/tmp/redis"}],
    
    {ok,RedisValues}=tiger_kv_util:get_env(redis,R),
    case proplists:get_value(enable,RedisValues) of
	true->
	    RedisPort=?PROPLIST_KEY_VALUE2(port,RedisValues,6379),
	    Ip1= ?PROPLIST_KEY_VALUE(ip,RedisValues,{127,0,0,1}),
	    {ok,_}=cowboy:start_listener(redis,100,cowboy_tcp_transport,[{port,RedisPort},{ip,Ip1}, {nodelay, true}],edis_client,[]),
	    erlcron:cron(proplists:get_value(snapshot,RedisValues)),
	    erlcron:cron(proplists:get_value(gc,RedisValues)),
	    R2={redis_back_end,
		    {edis_db, start_link,
		     [MasterNodes,[{bucket,?REDIS_BUCKET},{is_memory_db,true}],proplists:get_value(conf,RedisValues),
						   proplists:get_value(db_dir,RedisValues)]},
		permanent, 5000, worker, [redis_back_end]},
	    B2=get(?BACKEND),put(?BACKEND,[R2|B2]),
	    ok;
	_->
	    do_nothing
    end,
        
    % Build the process list...
    Processes = lists:flatten(get(?BACKEND)),
   % Processes = lists:flatten([
   %			       RedisBackEnd,
   %			       MemBackEnd
   % ]),    
    % Run the proesses...
    {ok, {{one_for_one, 10, 10}, Processes}}.



-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

getip_test()->
    ?assertEqual(getip_by_string("1.2.4.5"),{1,2,4,5}),
    ?assertEqual(getip_by_string("ttt"),{127,0,0,1}).
    

-endif.
