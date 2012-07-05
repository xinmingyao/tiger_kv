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

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD2(I, Type,Paras, Timeout), {I, {I, start_listener, Paras}, permanent, Timeout, Type, [I]}).
-define(CHILD2(I, Type,Paras), ?CHILD2(I, Type,Paras,5000)).
-define(CHILD(I, Type, Timeout), {I, {I, start_link, []}, permanent, Timeout, Type, [I]}).
-define(CHILD(I, Type), ?CHILD(I, Type, 5000)).
-define (IF (Bool, A, B), if Bool -> A; true -> B end).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================


init([]) ->
    
    {ok,MasterNodes}= tiger_core_util:get_env(master_nodes,['m1@127.0.0.1','m2@127.0.0.1','m3@127.0.0.1']),
    {ok,DbDir}=tiger_kv_util:get_env(memcached_db_dir,"/tmp/memcached"),

    RedisBackEnd = {redis_back_end,
		    {edis_db, start_link,
		     [MasterNodes,[{prefix,"aa"}],[]]},
		    permanent, 5000, worker, [redis_back_end]},
    MemBackEnd = {mem_back_end,
		    {memcached_backend, start_link,
		     [MasterNodes,[{prefix,"bb"}],DbDir]},
		    permanent, 5000, worker, [mem_back_end]},
    
    % Build the process list...
    Processes = lists:flatten([
			       RedisBackEnd,
			       MemBackEnd
    ]),    
    % Run the proesses...
    {ok, {{one_for_one, 10, 10}, Processes}}.



