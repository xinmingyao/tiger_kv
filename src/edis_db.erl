%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @author Chad DePue <chad@inakanetworks.com>
%%% @copyright (C) 2011 InakaLabs SRL
%%% @doc edis Database
%%% @todo It's currently delivering all operations to the leveldb instance, i.e. no in-memory management
%%%       Therefore, operations like save/1 are not really implemented
%%% @todo We need to evaluate which calls should in fact be casts
%%% @todo We need to add info to INFO
%%% @end
%%%-------------------------------------------------------------------
-module(edis_db).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').
-author('Chad DePue <chad@inakanetworks.com>').

-behaviour(gen_zab_server).
-compile([{parse_transform, lager_transform}]). 
-include("edis.hrl").
-include("tiger_kv_main.hrl").
-define(DEFAULT_TIMEOUT, 5000).
-define(RANDOM_THRESHOLD, 500).

-type item_type() :: string | hash | list | set | zset.
-type item_encoding() :: raw | int | ziplist | linkedlist | intset | hashtable | zipmap | skiplist.
-export_type([item_encoding/0, item_type/0]).

-record(state, {
	  db::reference(),
	  index               :: non_neg_integer(),
	  start_time          :: pos_integer(),
	  accesses            :: dict(),
	  updates             :: dict(),
	  blocked_list_ops    :: dict(),
	  last_save           :: float()}).
-opaque state() :: #state{}.

%% Administrative functions
-export([start_link/3, process/1]).
-export([init/1, handle_call/4, handle_cast/3, handle_info/3, terminate/3, code_change/4,handle_commit/4]).

%% Commands ========================================================================================
-export([run/2, run/3]).

%% =================================================================================================
%% External functions
%% =================================================================================================

%% @doc starts a new db client

start_link(Nodes,Opts,Index) ->
    gen_zab_server:start_link(?MODULE,Nodes,Opts, ?MODULE, [Index], []).



%% @doc returns the database name with index Index 
%% You can use that value later on calls to {@link run/2} or {@link run/3}
-spec process(non_neg_integer()) -> atom().
process(Index) ->
    edis_db.
 % list_to_atom("edis-db" ++ integer_to_list(Index)).

%% =================================================================================================
%% Commands
%% =================================================================================================
%% @equiv run(Db, Command, 5000)
-spec run(atom(), edis:command()) -> term().
run(Db, Command) ->
  run(Db, Command, ?DEFAULT_TIMEOUT).

%% @doc Executes Command in Db with some Timeout 
-spec run(atom(), edis:command(), infinity | pos_integer()) -> term().
run(Db, Command, Timeout) ->
  ?DEBUG("CALL for ~p: ~p~n", [Db, Command]),
    
    Re=case Command of
	   #edis_command{cmd = <<"MSET">>} ->
	       gen_zab_server:proposal_call(Db,Command,Timeout);
	    #edis_command{cmd = <<"SET">>} ->
	       gen_zab_server:proposal_call(Db,Command,Timeout);
	   #edis_command{cmd = <<"DEL">>} ->
	       gen_zab_server:proposal_call(Db,Command,Timeout);
	    _->
	       gen_zab_server:call(Db, Command, Timeout) 
	   end,
    lager:info("result ~p",[Re]),
    case Re of
	{ok,ok}->ok;
	ok -> ok;
	{ok, Reply} -> Reply;
	{error, Error} ->
	    ?THROW("Error trying ~p on ~p:~n\t~p~n", [Command, Db, Error]),
	    throw(Error)
    end
  .

%% =================================================================================================
%% Server functions
%% =================================================================================================
%% @hidden
-spec init(non_neg_integer()) -> {ok, state()} | {stop, any()}.
init(Index) ->
    {ok,Db}=eredis:open(a),
    {ok,#state{db=Db,index=Index},{0,0}}.


%% @hidden
-spec handle_call(term(), reference(), state(),zabinfo) -> {reply, ok | {ok, term()} | {error, term()}, state()} | {stop, {unexpected_request, term()}, {unexpected_request, term()}, state()}.
handle_call(#edis_command{cmd = <<"PING">>}, _From, State,_ZabServerInfo) ->
  {reply, {ok, <<"PONG">>}, State};
handle_call(#edis_command{cmd = <<"ECHO">>, args = [Word]}, _From, State,_ZabServerInfo) ->
  {reply, {ok, Word}, State};
%% -- Strings --------------------------------------------------------------------------------------
handle_call(#edis_command{cmd = <<"GET">>, args = [Key]}, _From, State,_ZabServerInfo) ->
    
Reply =
    case eredis:get(State#state.db, Key) of
      
	not_found -> {ok, undefined};
	{error, Reason} -> {error, Reason};
	{ok,V1}-> V2=binary_to_term(V1),
		  #edis_item{type = string, value = Value}=V2
		      , {ok, Value}
    end,
    ?INFO("~p",[Reply]),
  {reply, Reply, stamp(Key, read, State)};


handle_call(#edis_command{}, _From, State,_ZabServerInfo) ->
  {reply, {error, unsupported}, State};
handle_call(X, _From, State,_ZabServerInfo) ->
  {stop, {unexpected_request, X}, {unexpected_request, X}, State}.



handle_commit(#edis_command{cmd = <<"MGET">>, args = Keys},_Zxid, State,_ZabServerInfo) ->
  Reply =
    lists:foldr(
      fun(Key, {ok, AccValues}) ->
              case get_item(eredis, State#state.db, string, Key) of
                #edis_item{type = string, value = Value} -> {ok, [Value | AccValues]};
                not_found -> {ok, [undefined | AccValues]};
                {error, bad_item_type} -> {ok, [undefined | AccValues]};
                {error, Reason} -> {error, Reason}
              end;
         (_, AccErr) -> AccErr
      end, {ok, []}, Keys),
  {ok, Reply, stamp(Keys, read, State)};
handle_commit(#edis_command{cmd = <<"MSET">>, args = KVs}, _Zxid, State,_ZabServerInfo) ->
  Reply =      
        [
	 eredis:put(
	   State#state.db,Key,
	   term_to_binary(#edis_item{key = Key, encoding = raw,
		      type = string, value = Value})) || {Key, Value} <- KVs],
  {ok, ok, stamp([K || {K, _} <- KVs], write, State)};
handle_commit(#edis_command{cmd = <<"SET">>, args = [Key, Value]}, From, State,ZabServerInfo) ->
  handle_commit(#edis_command{cmd = <<"MSET">>, args = [{Key, Value}]}, From, State,ZabServerInfo);

%% -- Keys -----------------------------------------------------------------------------------------
handle_commit(#edis_command{cmd = <<"DEL">>, args = Keys}, _From, State,_ZabServerInfo) ->
  DeleteActions =
      [eredis:delete(State#state.db, Key) || Key <- Keys],
  Reply =
	{ok, length(DeleteActions)},

  {ok, Reply, stamp(Keys, write, State)}.

%% @hidden

handle_cast(X, State,_) -> {stop, {unexpected_request, X}, State}.

%% @hidden

handle_info(_, State,_) -> {noreply, State, hibernate}.

%% @hidden

terminate(_, _,_) -> ok.

%% @hidden

code_change(_OldVsn, State, _Extra,_) -> {ok, State}.

%% =================================================================================================
%% Private functions
%% =================================================================================================
%% @private
stamp(_, _Action, State) -> State.


%% @private

%% @private

%% @private
get_item(Mod, Ref, Types, Key) when is_list(Types) ->
  case get_item(Mod, Ref, any, Key) of
    Item = #edis_item{type = T} ->
      case lists:member(T, Types) of
        true -> Item;
        false -> {error, bad_item_type}
      end;
    Other ->
      Other
  end;
get_item(Mod, Ref, _Type, Key) ->
  case Mod:get(Ref, Key) of
    
      not_found ->
	  not_found;
      {error, Reason} ->
	  {error, Reason};
      Item1 when is_binary(Item1)->
	  Item=binary_to_term(Item1),
	   #edis_item{type = _T, expire = Expire} =Item,
	  Now = edis_util:now(),
	  case Expire of
        Expire when Expire >= Now ->
          Item; 
        _ ->
          _ = Mod:delete(Ref, Key),
          not_found
      end;
      _ ->{error,bad_item_type}
  end.
