%%%-------------------------------------------------------------------
%%% @author  <>
%%% @copyright (C) 2012, 
%%% @doc
%%%
%%% @end
%%% Created : 19 Jun 2012 by  <>
%%%-------------------------------------------------------------------
-module(memcached_backend).
-behaviour(gen_zab_server). 
%% API
-export([start_link/3]).
-compile([{parse_transform, lager_transform}]).
%% gen_server callbacks
-export([init/1, handle_call/4, handle_cast/3, handle_info/3,
	 terminate/3, code_change/4]).

-define(SERVER, ?MODULE). 
-include("tiger_kv_main.hrl").
-record(state, {leveldb}).

-export([put/2,get/2,delete/1,get/1]).

-export([handle_commit/4]).

-define(LAST_ZXID_KEY,<<"cen_last_zxid_key">>).

%%%===================================================================
%%% API
%%%===================================================================
-spec put(Key::binary(),Value::binary())->ok|not_ready|timeout.
put(Key,Value)->
    gen_zab_server:proposal_call(?SERVER,{put,Key,Value})
    .

-spec delete(Value::binary())->ok|not_ready|timeout.
delete(Key)->
    gen_zab_server:proposal_call(?SERVER,{delete,Key}) 
    .
-spec get(Key::binary(),Ref::nif_ref)->{ok,Value::binary()}.
get(Key,Ref)->
    eleveldb:get(Ref,Key,[]).

get(Key)->
    gen_zab_server:call(?SERVER,{get,Key})
    .

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Nodes,Opts,DbDir) ->
    gen_zab_server:start_link(?SERVER,Nodes,Opts, ?MODULE, [DbDir], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([WorkDir]) ->    
    case eleveldb:open(WorkDir, [{create_if_missing, true},
				 {max_open_files,tiger_kv_util:get_env(backend_max_open_files,50)},
				 {write_buffer_size,tiger_kv_util:get_env(backend_write_buffer_size,50*1024*1024)},
				 {cache_size,tiger_kv_util:get_env(backend_cache_size,50*1024*1024)}
				]) of
        {ok, Ref} ->
	    true=tiger_global:put(?MODULE,{Ref}),
	    lager:notice("open db on:~p ok",[WorkDir]),
	    case eleveldb:get(Ref,?LAST_ZXID_KEY,[]) of
		{ok,Value}->
		    {ok,#state{leveldb=Ref},binary_to_term(Value)};
		not_found->
		    {ok,#state{leveldb=Ref},{0,0}};
		{error,Reason}->
		    lager:error("get last zxid error ~p",[Reason]),
		    {error,Reason}
	    end
            ;
        {error, Reason} ->
	    lager:error("open db error ~p",[Reason]),
            {error, Reason}
    end.

handle_commit({delete,Key},Zxid, State=#state{leveldb=Db},_ZabServerInfo) ->   
    Para=[{delete, Key},{put,?LAST_ZXID_KEY,term_to_binary(Zxid)}],
    Reply=eleveldb:write(Db,Para,[]),
    {ok,Reply,State};
handle_commit({put,Key,Value},Zxid, State=#state{leveldb=Db},_ZabServerInfo) ->   
    Para=[{put,Key,Value},{put,?LAST_ZXID_KEY,term_to_binary(Zxid)}],
    Reply=eleveldb:write(Db,Para,[]),
    {ok,Reply,State}
.
%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------

handle_call({get,Key}, _From, State=#state{leveldb=Db},_) ->
    case eleveldb:get(Db,Key,[]) of
	{ok,Value}->
	    {reply,{ok,Value}, State};
	not_found->
	    {reply,not_found, State};
	{error,Reason} ->
	    {reply, {error,Reason}, State}
    end;
handle_call(_, _From, State,_) ->
    {reply,ok,State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State,_) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info(_Info, State,_ZabServerInfo) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State,_ZabServerInfo) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra,_ZabServerInfo) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
