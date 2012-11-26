%%%-------------------------------------------------------------------
%%% @author  <>
%%% @copyright (C) 2012, 
%%% @doc
%%%
%%% @end
%%% Created : 19 Jun 2012 by  <>
%%%-------------------------------------------------------------------
-module(redis_backend).
-behaviour(gen_zab_server). 
%% API
-export([start_link/4]).
-compile([{parse_transform, lager_transform}]).
%% gen_server callbacks
-export([init/1, handle_call/4, handle_cast/3, handle_info/3,
	 terminate/3, code_change/4]).
-define(SERVER, ?MODULE). 
-include("tiger_kv_main.hrl").

-record(state, {
	  db::reference(),
	  index               :: non_neg_integer(),
	  start_time          :: pos_integer(),
	  accesses            :: dict(),
	  updates             :: dict(),
	  blocked_list_ops    :: dict(),
	  redis_db_dir        :: string(),
	  last_snap_filename ::string(),
	  last_save           :: float()}).
-opaque state() :: #state{}.
-export([put/2,get/1,delete/1]).
-export([do_snapshot/2,send_snapshot/0,send_gc/0]).




-export([handle_commit/4]).


%%%===================================================================
%%% API
%%%===================================================================

put(Key,Value)->
    case catch  gen_zab_server:proposal_call(?SERVER,{put,Key,Value}) of
        {error,not_ready} ->
            {error,not_ready};
	{ok,Res} ->
            Res;
        {'EXIT',Reason} ->
            {error,Reason};
	Res->
	    Res
    end
   %
    .
delete(Key)->
    case catch  gen_zab_server:proposal_call(?SERVER,{delete,Key}) of
        {error,not_ready} ->
            {error,"not_ready"};
	{ok,Res} ->
            Res;
        {'EXIT',Reason} ->
            {error,Reason};
	Res->
	    Res
    end
    .
get(Key)->
    case catch  gen_zab_server:call(?SERVER,{get,Key}) of
        {'EXIT',Reason} ->
            {error,Reason};
	Res->
	    Res
    end
    .

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link(Nodes,Opts,Conf,DbDir) ->
    gen_zab_server:start_link(?MODULE,Nodes,Opts, ?MODULE, [Conf,DbDir], []).

send_snapshot()->
    erlang:send(?MODULE,{zab_system,snapshot}).

send_gc()->
    erlang:send(?MODULE,{zab_system,gc}).

do_snapshot(LastZxid,State)->
    T= zabe_util:encode_zxid(LastZxid),
    FileName=filename:join(State#state.redis_db_dir,T++".rdb"),
    lager:notice("start snapshot db file_name:~p:",[FileName]),
    case eredis_engine:save_db(State#state.db,FileName) of
	ok->
	    lager:notice("snapshot db:~p ok",[FileName]),
	    {ok,State#state{last_snap_filename=FileName}};
	_-> lager:error("db snapshot error"),
	    {error,"save error"}
    end.

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
-spec init(list()) -> {ok, state()} | {stop, any()}.
init([Conf,DbDir]) ->
    {LastFile,Zxid}=case get_last_file_name(DbDir) of
			{ok,T}->
				{filename:join(DbDir,T++".rdb"),zabe_util:decode_zxid(T)};
			_->{0,{0,0}}
		    end,
    LastFile,
    {ok,Db}=
     case LastFile of
	 0->eredis_engine:open("nouse",Conf,0);
	 _->
	     lager:debug("open rdb: ~p",[LastFile]),
	     eredis_engine:open(LastFile,Conf,1)
     end,
    {ok,#state{db=Db,redis_db_dir=DbDir},Zxid}.

handle_commit({delete,Key},_Zxid, State=#state{db=Db},_ZabServerInfo) ->   
  
    Reply=eredis_engine:delete(Db,Key),
    {ok,Reply,State};
handle_commit({put,Key,Value},_Zxid, State=#state{db=Db},_ZabServerInfo) ->   
    Reply=eredis_engine:put(Db,Key,Value),
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

handle_call({get,Key}, _From, State=#state{db=Db},_) ->
    case eredis_engine:get(Db,Key) of
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


get_last_file_name(DbDir)->
    Files=filelib:fold_files(DbDir,".rdb",false,fun(Name,Acc)->
							N2=filename:basename(Name,".rdb"),
						   if
						       length(N2)=:=30->[N2|Acc] ;
						       true ->Acc
						   end
						 end ,[]),

    F2=lists:sort(fun(A,B)->
		       Z1=zabe_util:decode_zxid(A),
		       Z2=zabe_util:decode_zxid(B),
		       zabe_util:zxid_big(Z1,Z2) end ,Files),
    
  case F2 of
      []->
	  empty;
      [H|_] ->{ok,H}
  end.
-ifdef(TEST).
 -include_lib("eunit/include/eunit.hrl").
get_file_name_test()->
    ?assertEqual(get_last_file_name("./"),empty),
    ?assertCmd("touch ./111111111111111111111111111111.rdb"),
    ?assertCmd("touch ./111111111111111111111111111112.rdb"),
    ?assertEqual({ok,"111111111111111111111111111112"},get_last_file_name("./")),
    ?assertCmd("rm -f ./*.rdb"),
    ok.

-endif.

