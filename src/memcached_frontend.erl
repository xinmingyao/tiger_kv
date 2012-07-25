%get%%----------------------------------------------------------------------
%%% OneCached (c) 2007-2008 ProcessOne (http://www.process-one.net/)
%%% $Id$
%%%----------------------------------------------------------------------

-module(memcached_frontend).
-author('jerome.sautret@process-one.net').
-vsn('$Revision$ ').

% Code for the threads that handle client connexions

-behaviour(gen_fsm).
-define(VERSION, "OneCached v1.0 by ProcessOne (http://www/process-one.net/)").

-author('jerome.sautret@process-one.net').
-vsn('$Revision$ ').

-include("tiger_kv_main.hrl").

%% External exports
-export([start_link/4, stop/1]).
%% internal function
-export([loop/3]).

%% gen_fsm callbacks
-export([init/1,
	 process_command/2,
	 process_data_block/2,
	 discard_data_block/2,
	 handle_event/3,
	 handle_sync_event/4,
	 handle_info/3,
	 terminate/3,
	 code_change/4]).

-record(state, {socket, storage, command}).

%%====================================================================
%% API
%%====================================================================
%%--------------------------------------------------------------------
%% Function: start() -> {ok,Pid} | ignore | {error,Error}
%% Description: Starts the server
%%--------------------------------------------------------------------

stop(Pid) ->
    gen_fsm:send_all_state_event(Pid, stop).


start_link (_ListenPid,Socket,Transport,TransOps) ->
    gen_fsm:start_link( ?MODULE, [Socket,Transport,TransOps],[]).

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
    
    inet:setopts(Socket,[list,
			       {packet, raw},
			       {active, false},
			       {reuseaddr, true},
			       {nodelay, true},
			       {keepalive, true}]),
    Storage = mnesia, % TODO -> get from parameters
    % run TCP server
    _Pid = proc_lib:spawn_link(?MODULE, loop, [self(), Socket, ""]),
    {ok, process_command, #state{socket=Socket, storage=Storage}}.

%%====================================================================
%% TCP server
%%====================================================================

% receive TCP packets
loop(FSM_Pid, Socket, Data) ->
    %?DEBUG("loop ~p~n", [Socket]),
    case gen_tcp:recv(Socket, 0) of
	{ok, Packet} ->
	    %?DEBUG("Packet Received~n~p~n", [Packet]),
	    NewData = process_packet(FSM_Pid, Data++Packet),
	    loop(FSM_Pid, Socket, NewData);
	{error, closed} ->
	    ?DEBUG("closed~n", []),

	    ok;
	{error, Reason} ->
	    ?ERROR_MSG("Error receiving on socket ~p: ~p~n", [Socket, Reason]),
	    {error, Reason}
    end.

% parse TCP packet to find lines, and send them to the FSM
process_packet(FSM_Pid, Data) ->
    case read_line(Data) of
	{line, Line, NewData} ->
	    ?DEBUG("Line~n~p", [Line]),
	    gen_fsm:send_event(FSM_Pid, {line, Line}),
	    process_packet(FSM_Pid, NewData);
	 noline ->
	    Data
    end.

% Try to find the first line in the Data.
% return {line, Line, Rest_of_date} if found or
% noline
read_line(Data) ->
    read_line(Data, "").
read_line("", _Line) ->
    noline;
read_line("\r\n" ++ Data, Line) ->
    {line, lists:reverse(Line), Data};
read_line([Char|Data], Line) ->
    read_line(Data, [Char | Line]).

%%====================================================================
%% FSM Callbacks
%%====================================================================

% memcached "set" storage command line
process_command({line, "set "++Line}, StateData) ->
    {next_state, process_data_block, StateData#state{command=parse_storage_command(Line)}};
% memcached "add" storage command line
process_command({line, "add "++Line}, StateData) ->
    StorageCommand = parse_storage_command(Line),
    case StorageCommand of
	#storage_command{key=Key} ->
	    NewStorageCommand = StateData#state{command=StorageCommand},
	    case catch onecached_storage:has_item(StateData#state.storage, Key) of
		false ->
		    {next_state, process_data_block, NewStorageCommand};
		_ ->
		    {next_state, discard_data_block, NewStorageCommand}
	    end;
	_ ->
	    ?ERROR_MSG("CLIENT_ERROR invalid command format~n~p~n", [Line]),
	    send_command(StateData#state.socket, "CLIENT_ERROR invalid command format "++Line),
	    {next_state, process_command, StateData}
    end;

% memcached "replace" storage command line
process_command({line, "replace "++Line}, StateData) ->
    StorageCommand = parse_storage_command(Line),
    case StorageCommand of
	#storage_command{key=Key} ->
	    NewStorageCommand = StateData#state{command=StorageCommand},
	    case catch onecached_storage:has_item(StateData#state.storage, Key) of
		true ->
		    {next_state, process_data_block, NewStorageCommand};
		_ ->
		    {next_state, discard_data_block, NewStorageCommand}
	    end;
	_ ->
	    ?ERROR_MSG("CLIENT_ERROR invalid command format~n~p~n", [Line]),
	    send_command(StateData#state.socket, "CLIENT_ERROR invalid command format "++Line),
	    {next_state, process_command, StateData}
    end;

% memcached "get" retrieval command line
process_command({line, "get "++Line}, #state{socket=Socket, storage=Storage}=StateData) ->
    Keys = parse_retrieval_command(Line),
    lists:foreach(fun(Key) ->
			  send_item(Socket, Storage, Key)
		  end, Keys),
    send_command(Socket, "END"),
    {next_state, process_command, StateData};

% memcached "incr" command line
process_command({line, "incr "++Line}, StateData) ->
    process_incr_decr_command(fun(A, B) -> A+B end, Line, StateData);
process_command({line, "decr "++Line}, StateData) ->
    process_incr_decr_command(fun(A, B) -> A-B end, Line, StateData);

% memcached "delete" command line
% TODO second time argument support
process_command({line, "delete "++Line}, #state{socket=Socket, storage=Storage}=StateData) ->
    case parse_delete_command(Line) of
	{Key, _Time} ->
	    case catch onecached_storage:delete_item(Storage, Key) of
		ok ->
		    send_command(Socket, "DELETED");
		none ->
		    send_command(Socket, "NOT_FOUND");
		{error,Other} ->
		    ?ERROR_MSG("SERVER_ERROR~n~p~n", [Other]),
		    send_command(Socket, io_lib:format("SERVER_ERROR ~p", [Other]))
	    end;
	_ ->
	    ?ERROR_MSG("CLIENT_ERROR invalid delete command format~n~p~n", [Line]),
	    send_command(Socket, "CLIENT_ERROR invalid delete command format: delete "++Line)
    end,
    {next_state, process_command, StateData};

% memcached "flush_all" command line
% TODO second time argument support
process_command({line, "flush_all"++_Line}, #state{socket=Socket, storage=Storage}=StateData) ->
    case catch onecached_storage:flush_items(Storage) of
	ok ->
	    send_command(Socket, "OK");
	Other ->
	    ?ERROR_MSG("SERVER_ERROR~n~p~n", [Other]),
	    send_command(Socket, io_lib:format("SERVER_ERROR ~p", [Other]))
    end,
    {next_state, process_command, StateData};

% memcached "quit" command line
process_command({line, "quit"}, StateData) ->
    {stop, normal, StateData};

% unknown memcached command
process_command({line, Line}, #state{socket=Socket} = StateData) ->
    ?ERROR_MSG("CLIENT_ERROR unknown command~n~p~n", [Line]),
    send_command(Socket, "CLIENT_ERROR unknown command "++Line),
    {next_state, process_command, StateData}.

% process data block that won't be stored
discard_data_block({line, Line}, #state{socket=Socket,
					command=#storage_command{bytes=Bytes}} = StateData) ->
    case length(Line) of
	Bytes ->
	    send_command(Socket, "NOT_STORED"),
	    {next_state, process_command, StateData#state{command=undefined}};
	Length ->
	    % -2 because we count the discarded "\r\n" in the Data block
	    {next_state, discard_data_block, StateData#state{command=#storage_command{bytes=Bytes-Length-2}}}
    end;
discard_data_block({line, Line}, #state{socket=Socket} = StateData) ->
    ?ERROR_MSG("CLIENT_ERROR invalid command format~n~p~nState;~p~n", [Line, StateData]),
    send_command(Socket, "CLIENT_ERROR invalid command format "++Line),
    {next_state, process_command, StateData}.

% process data block that will be stored
process_data_block({line, Line}, #state{socket=Socket,
					storage=Storage,
					command=StorageCommand}=StateData)
  when is_record(StorageCommand, storage_command) ->
    Data = StorageCommand#storage_command.data,
    NewData = case Data of
		  "" ->
		      Line;
		  _ -> Data ++ "\r\n" ++ Line
	      end,
    NewStorageCommand = StorageCommand#storage_command{data=NewData},
    Bytes = StorageCommand#storage_command.bytes,
    case length(NewData) of
	Bytes ->
	    case catch onecached_storage:store_item(Storage, NewStorageCommand) of
		ok ->
		    send_command(Socket, "STORED");
		{error,Other} when is_list(Other) ->
		    ?ERROR_MSG("SERVER_ERROR~n~p~n", [Other]),
		    send_command(Socket, "SERVER_ERROR "++Other)
	    end,
	    {next_state, process_command, StateData#state{command=undefined}};
	_Length ->
	    {next_state, process_data_block,
	     StateData#state{command=NewStorageCommand}}
    end;
process_data_block({line, Line}, #state{socket=Socket} = StateData) ->
    ?ERROR_MSG("CLIENT_ERROR invalid command format~n~p~n", [Line]),
    send_command(Socket, "CLIENT_ERROR invalid command format "++Line),
    {next_state, process_command, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_event/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_event(stop, _StateName, StateData) ->
    {stop, normal, StateData};
handle_event(_Event, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_sync_event/4
%% Returns: {next_state, NextStateName, NextStateData}            |
%%          {next_state, NextStateName, NextStateData, Timeout}   |
%%          {reply, Reply, NextStateName, NextStateData}          |
%%          {reply, Reply, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}                          |
%%          {stop, Reason, Reply, NewStateData}
%%----------------------------------------------------------------------
handle_sync_event(_Event, _From, StateName, StateData) ->
    Reply = ok,
    {reply, Reply, StateName, StateData}.
code_change(_OldVsn, StateName, StateData, _Extra) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: handle_info/3
%% Returns: {next_state, NextStateName, NextStateData}          |
%%          {next_state, NextStateName, NextStateData, Timeout} |
%%          {stop, Reason, NewStateData}
%%----------------------------------------------------------------------
handle_info(_Info, StateName, StateData) ->
    {next_state, StateName, StateData}.

%%----------------------------------------------------------------------
%% Func: terminate/3
%% Purpose: Shutdown the fsm
%% Returns: any
%%----------------------------------------------------------------------
terminate(_Reason, _StateName, _StateData) ->
    ok.


%%====================================================================
%% Communication functions
%%====================================================================

send_command(Socket, Command) ->
    gen_tcp:send(Socket, Command++"\r\n").

send_item(Socket, Storage, Key) ->
    case catch onecached_storage:get_item(Storage, Key) of
	{ok, {Flags, Data}} ->
	    SData = case Data of
			Value when is_integer(Value) ->
			    integer_to_list(Value);
			Value when is_list(Value) ->
			    Value;
			Value when is_binary(Value) ->
			    binary_to_list(Value)
		    end,
	    send_command(Socket,
			 io_lib:format("VALUE ~s ~w ~w", [Key, Flags, length(SData)])),
	    send_command(Socket, SData);
	none ->
	    ok;
	{error,Other} ->
	    ?ERROR_MSG("SERVER_ERROR~n~p~n", [Other]),
	    send_command(Socket, "SERVER_ERROR "++Other)
    end.

%%====================================================================
%% Helper functions
%%====================================================================

% Format of Line is
% <key> <flags> <exptime> <bytes>
% return #storage_command or error
parse_storage_command(Line) ->
    case string:tokens(Line, " ") of
	[Key, SFlags, SExptime, SBytes] ->
	    case {string:to_integer(SFlags),
		  string:to_integer(SExptime),
		  string:to_integer(SBytes)} of
		{{Flags, ""}, {Exptime, ""}, {Bytes, ""}} ->
		    #storage_command{key = Key,
				     flags = Flags,
				     exptime = Exptime,
				     bytes = Bytes};
		_ ->
		    error
	    end;
	_ ->
	    error
    end.

% Format of Line is
% <key>*
% return [Key] when is_list(Key)
parse_retrieval_command(Line) ->
    string:tokens(Line, " ").

% Format of Line is
% <key> <time>?
% return {Key, Time}
parse_delete_command(Line) ->
    case string:tokens(Line, " ") of
	[Key, STime] ->
	    case string:to_integer(STime) of
		{Time, ""} ->
		    {Key, Time};
		_ ->
		    error
	    end;
	[Key] ->
	    {Key, 0};
	_ ->
	    error
    end.

% Format of Line is
% <key> <value>
% return {Key, Value} when is_integer(Value)
parse_incr_decr_command(Line) ->
    case string:tokens(Line, " ") of
	[Key, SValue] ->
	    case string:to_integer(SValue) of
		{Value, ""} ->
		    {Key, Value};
		_ ->
		    error
	    end;
	_ ->
	    error
    end.


process_incr_decr_command(Operation, Line, #state{socket=Socket, storage=Storage} = StateData) ->
    case parse_incr_decr_command(Line) of
	{Key, Value} ->
	    case catch onecached_storage:update_item_value(Storage, Key, Value, Operation) of
		{ok, NewValue} ->
		    send_command(Socket, integer_to_list(NewValue));
		none ->
		    send_command(Socket, "NOT_FOUND");
		Other ->
		    ?ERROR_MSG("SERVER_ERROR~n~p~n", [Other]),
		    send_command(Socket, io_lib:format("SERVER_ERROR ~p", [Other]))
	    end;
	_ ->
	    ?ERROR_MSG("CLIENT_ERROR invalid incr/decr command format~n~p~n", [Line]),
	    send_command(Socket, "CLIENT_ERROR invalid incr/decr command format: "++Line)
    end,
    {next_state, process_command, StateData}.
