%%%-------------------------------------------------------------------
%%% @author  <yaoxinming@gmail.com>
%%% @copyright (C) 2012, 
%%% @doc
%%%
%%% @end
%%% Created : 26 Nov 2012 by  <>
%%%-------------------------------------------------------------------
-module(mem_frontend).

-behaviour(gen_server).
%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-compile([{parse_transform, lager_transform}]).
-define(SERVER, ?MODULE). 

-record(state, {parser_state,socket,nif_ref}).
-include("tiger_kv_main.hrl").
-include("memcached_pb.hrl").
%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------

start_link (_ListenPid,Socket,Transport,TransOps) ->
    gen_server:start_link( ?MODULE, [Socket,Transport,TransOps],[]).


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
init([Socket,_,_]) ->
    inet:setopts(Socket,[binary,
			       {packet, raw},
			       {active, once},
			       {reuseaddr, true},
			       {nodelay, true},
			       {keepalive, true}]),
    {ok,{Ref}}=tiger_global:get(memcached_backend),
    {ok, #state{socket=Socket,parser_state=#memstate{state=init},nif_ref=Ref}}.

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
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

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
handle_cast(_Msg, State) ->
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
handle_info({tcp, Socket, Bin}, #state{socket = Socket,parser_state=ParserState
				      } = StateData) ->
    lager:debug("~p~n",[Bin]),
    Result=case mem_parser:parse(ParserState,Bin) of
	       {ok,First,Second,NewParserState}->
		   Rep=process_req(First,Second),
		   lager:debug("~p~n",[Rep]),
		   gen_tcp:send(Socket,Rep),
		   StateData#state{parser_state=NewParserState};
	       {ok,Data,NewParserState}->
		   Rep=process_req2(Data,StateData),
		   lager:debug("~p~n",[Rep]),
		   send_tcp(Socket,Rep),
		   StateData#state{parser_state=NewParserState};
	       {continue,NewParserState}->
		   StateData#state{parser_state=NewParserState}
	   end,
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply,Result};
handle_info({tcp_closed, Socket},  #state{socket = Socket
                                                     } = StateData) ->
  {stop, normal, StateData};
handle_info(_Info, State) ->
    {noreply, State}.

send_tcp(Socket,Data) when is_list(Data) ->
    lists:map(fun(A)->
		      gen_tcp:send(Socket,A) end ,Data);
send_tcp(Socket,Data) ->
    gen_tcp:send(Socket,Data).
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
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
process_req(First,Second)->
    T=binary:split(First,<<" ">>,[global]),
    [Cmd,_K,_Flags,_ExpTime,_Size]=T,
    do_storage_cmd(Cmd,T,Second).
do_storage_cmd(<<"set">>,T,Second)->
    [_Cmd,K,Flags,ExpTime,S1]=T,
    Size=list_to_integer(binary_to_list(S1)),
    Exptime=erlang:list_to_integer(erlang:binary_to_list(ExpTime)),

    V=case
	Exptime of 
	0->
	    <<0:32,Size:32,Second/binary,Flags/binary>>;
	_->
	    {M, S, _MicroSecs}=now(),
	     T2= M*1000+S+Exptime,
	      <<T2:32,Size:32,Second/binary,Flags/binary>>

    end,
    Rep=case memcached_backend:put(K,V) of
	    ok->
		<<"STORED",?NL>>;
	    {error,"not_ready"}->
		<<"NOT_READY",?NL>>;
	    _ ->
		<<"SERVER_ERROR",?NL>>
	end,
    Rep.

process_req2(Data,State) ->
    T=binary:split(Data,<<" ">>,[global]),
    [Cmd|Tail]=T,
    do_retrieval(Cmd,Tail,State).
-define(WS," ").
do_retrieval(<<"get">>,Data,State)->
    L=lists:foldl(fun(Key,Acc)->
		       case eleveldb:get(State#state.nif_ref,Key,[]) of
			   {ok,Value}->
			       <<T:32,Size:32,Second:Size/binary,Flags/binary>> =Value,
			       S2=list_to_binary(integer_to_list(Size)),
			       case T of
				   0->

				       [<<"VALUE",?WS,Key/binary,?WS,Flags/binary,?WS,S2/binary,?NL,Second/binary,?NL>>|Acc]
					   ;
				   _->
				       {MegaSecs, Secs, _MicroSecs} = now(),
				       case T > MegaSecs*1000+Secs of
					   true ->
					       [<<"VALUE",?WS,Key/binary,?WS,Flags/binary,?WS,S2/binary,?NL,Second/binary,?NL>>|Acc];
					       
					   false ->
					       %%not block,
					       erlang:spawn(memcached_backend,delete,[Key]),
					       Acc
				       end
			       end;
			   not_found->
			       Acc;
			   _->
			       Acc
		       end
		 end,[],Data),
    lists:reverse([<<"END",?NL>>|L])
%	,L
	;
do_retrieval(<<"delete">>,Data,_State)->
    [Key|_]=Data,
    case memcached_backend:delete(Key) of
	ok->
	    <<"DELETED",?NL>>;
	{error,"not_ready"} ->
	    <<"NOT_READY",?NL>>;
	_ ->
	    <<"SERVER_ERROR",?NL>>
    end.
		

	
