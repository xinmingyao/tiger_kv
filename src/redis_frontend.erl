%%%-------------------------------------------------------------------
%%% @author  <yaoxinming@gmail.com>
%%% @copyright (C) 2012, 
%%% @doc
%%%
%%% @end
%%% Created : 26 Nov 2012 by  <>
%%%-------------------------------------------------------------------
-module(redis_frontend).

-behaviour(gen_server).

%% API
-export([start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).
-compile([{parse_transform, lager_transform}]).
-define(SERVER, ?MODULE). 

-record(state, {parser_state,socket,nif_ref,db_index=0}).
-include("tiger_kv_main.hrl").

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
    {ok,{Ref1}}=tiger_global:get(redis_backend),
    put(index,0),
    {ok, #state{socket=Socket,parser_state=#pstate{},nif_ref=Ref1},?CLIENT_SOCKET_TIMEOUT}.

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
    {reply, Reply, State,?CLIENT_SOCKET_TIMEOUT}.

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
    {noreply, State,?CLIENT_SOCKET_TIMEOUT}.

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
    Result=case redis_parser:parse(ParserState,Bin) of
	       {ok,Req,NewParserState}->
		   Rep=process_req(Req,StateData),
		   gen_tcp:send(Socket,Rep),
		   ok = inet:setopts(Socket, [{active, once}]),
		   StateData#state{parser_state=NewParserState};
	       {ok,Req,_Rest,NewParserState}->
		   Rep=process_req(Req,StateData),
		   gen_tcp:send(Socket,Rep),
		   ok = inet:setopts(Socket, [{active, once}]),
		   StateData#state{parser_state=NewParserState};
	       {continue,NewParserState}->
		   StateData#state{parser_state=NewParserState}
	   end,
    {noreply,Result,?CLIENT_SOCKET_TIMEOUT};
handle_info({tcp_closed, Socket},  #state{socket = Socket
                                                     } = StateData) ->

  {stop, normal, StateData};
handle_info(_Info, State) ->
    {noreply, State,?CLIENT_SOCKET_TIMEOUT}.

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
terminate(_Reason, State) ->
    catch gen_tcp:close(State#state.socket),
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
process_req([<<"SET">>,K,V],_Socket)->
    Rep=case catch redis_backend:put(K,V,get(index)) of
	    ok->
		<<"+OK",?NL>>;
	    timeout->
		<<"-timeout",?NL>>;
	    {error,not_ready}->
		<<"-not_ready",?NL>>;
	    _ ->
		<<"-error",?NL>>
	end,
    Rep;
process_req([<<"GET">>,K],State) ->
    Index=get(index),
    Rep=case  eredis_engine:get(State#state.nif_ref,K,Index) of
	    {ok,Value}->
		Size=erlang:size(Value),
		S=list_to_binary(erlang:integer_to_list(Size)),
		<<"$",S/binary,?NL,Value/binary,?NL>>
		;
	    not_found->
		<<"$-1",?NL>>;
	    _ ->
		<<"-error",?NL>>
	end,
    Rep;
process_req([<<"DEL">>,K],_Socket) ->
    Rep=case catch redis_backend:delete(K,get(index)) of
	    ok->
		<<"+OK",?NL>>;
	    timeout->
		<<"-timeout",?NL>>;
	    _ ->
		<<"-error",?NL>>
	end,
    Rep;
process_req([<<"SELECT",Rest/binary>>],_Socket) ->
    Index=list_to_integer(string:strip(binary_to_list(Rest))),
    if Index>16 ->
	    <<"-error db must less 16">>;
       true->
	    put(index,Index),
	    <<"+OK",?NL>>
    end;
process_req(<<"SELECT",Rest/binary>>,_Socket) ->
    Index=list_to_integer(string:strip(binary_to_list(Rest))),
    if Index>16 ->
	    <<"-error db must less 16">>;
       true->
	    put(index,Index),
	    <<"+OK",?NL>>
    end;
process_req([<<"PING">>],_Socket) ->
    <<"+PONG",?NL>>;
process_req(_A,_Socket) ->
    <<"-error_not_support",?NL>>.

	
