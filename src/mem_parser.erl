%%
%% Parser of the memcached protocol, see http://redis.io/topics/protocol
%%
%% The idea behind this parser is that we accept any binary data
%% available on the socket. If there is not enough data to parse a
%% complete response, we ask the caller to call us later when there is
%% more data. If there is too much data, we only parse the first
%% response and let the caller call us again with the rest.
%%
%% This approach lets us write a "pure" parser that does not depend on
%% manipulating the socket, which erldis and redis-erl is
%% doing. Instead, we may ask the socket to send us data as fast as
%% possible and parse it continously. The overhead of manipulating the
%% socket when parsing multibulk responses is killing the performance
%% 
%%
%% Future improvements:
%%  * Instead of building a binary all the time in the continuation,
%%    build an iolist
%%  * When we return a bulk continuation, we also include the size of
%%    the bulk. The caller may use this to explicitly call
%%    gen_tcp:recv/2 with the desired size.

-module(mem_parser).
-author('yaoxinming@gmail.com').

-export([init/0, parse/2]).
-include_lib("tiger_kv_main.hrl").
-include_lib("eunit/include/eunit.hrl").

%%
%% API
%%

%% @doc: Initialize the parser
init() ->
    #memstate{state=init}.
 

-spec parse(State::#memstate{}, Data::binary()) ->
                   {ok, return_value(), NewState::#pstate{}} |
                       {ok, return_value(), Rest::binary(), NewState::#pstate{}} |
                       {error, ErrString::binary(), NewState::#pstate{}} |
                       {error, ErrString::binary(), Rest::binary(), NewState::#pstate{}} |
                       {continue, NewState::#pstate{}}.

%% @doc: Parses the (possibly partial) response from Redis. Returns
%% either {ok, Value, NewState}, {ok, Value, Rest, NewState} or
%% {continue, NewState}. External entry point for parsing.
%%
%% In case {ok, Value, NewState} is returned, Value contains the value
%% returned by Redis. NewState will be an empty parser state.
%%
%% In case {ok, Value, Rest, NewState} is returned, Value contains the
%% most recent value returned by Redis, while Rest contains any extra
%% data that was given, but was not part of the same response. In this
%% case you should immeditely call parse again with Rest as the Data
%% argument and NewState as the State argument.

%% In case {continue, NewState} is returned, more data is needed
%% before a complete value can be returned. As soon as you have more
%% data, call parse again with NewState as the State argument and any
%% new binary data as the Data argument.

%% Parser in initial state, the data we receive will be the beginning
%% of a response

do_parse_storage(First,Rest,State)->
    case parse_simple(Rest) of
	{ok,V,R2}->
	    {ok,First,V,State#memstate{state = first_continue, continuation_data = R2}};
	{continue, Data}->
	    {continue, State#memstate{state = storage_continue, storage_data=First,continuation_data = Data}}
    end.
parse(#memstate{state = init} = State, NewData) ->
    case  parse_simple(NewData) of
	{ok,<<"set",_/binary>>=First,Rest}->
	    do_parse_storage(First,Rest,State);
	{ok,<<"add",_/binary>>=First,Rest}->
	    do_parse_storage(First,Rest,State);
	{ok,<<"get",_Rest/binary>>=C,R3}->
	    {ok,C,State#memstate{state = first_continue, continuation_data = R3}};
	{ok,<<"delete",_Rest/binary>>=C,R3}->
	    {ok,C,State#memstate{state = first_continue, continuation_data = R3}};
	{continue,  Data} ->
	    {continue, State#memstate{state = first_continue, continuation_data = Data}}
    end;
parse(#memstate{state = first_continue,
              continuation_data = OldDate} = State, NewData) ->
    case  parse_simple(OldDate,NewData) of
	{ok,<<"set",_/binary>>=First,Rest}->
	    do_parse_storage(First,Rest,State);
	{ok,<<"add",_/binary>>=First,Rest}->
	    do_parse_storage(First,Rest,State);
	{ok,<<"get",_Rest/binary>>=C,R3}->
	    {ok,C,State#memstate{state = first_continue, continuation_data = R3}};
	{ok,<<"delete",_Rest/binary>>=C,R3}->
	    {ok,C,State#memstate{state = first_continue, continuation_data = R3}};
	{continue,Data} ->
	    {continue, State#memstate{state = first_continue, continuation_data = Data}}
    end;

parse(#memstate{state = storage_continue,storage_data=StorageData,
              continuation_data = OldData} = State, NewData) ->
    case  parse_simple(OldData,NewData) of
	{ok,Value,R3}->
	    {ok,StorageData,Value,State#memstate{state = first_continue, continuation_data = R3}};
	{continue,  Data} ->
	    {continue, State#memstate{state = storage_continue, continuation_data = <<OldData/binary,Data/binary>>}}
    end.

%% @doc: Parse simple replies. Data must not contain type
%% identifier. Type must be handled by the caller.

parse_simple(Data) ->
    case get_newline_pos(Data) of
        undefined ->
            {continue, Data};
        NewlinePos ->
            <<Value:NewlinePos/binary, ?NL, Rest/binary>> = Data,
            {ok, Value, Rest}
    end.

parse_simple(OldData, NewData0) ->
    NewData = <<OldData/binary, NewData0/binary>>,
    parse_simple(NewData).

%%
%% INTERNAL HELPERS
%%
get_newline_pos(B) ->
    case re:run(B, ?NL) of
        {match, [{Pos, _}]} -> Pos;
        nomatch -> undefined
    end.



-ifdef(TEST).
 -include_lib("eunit/include/eunit.hrl").
get_test()->
    State=init(),
    R=parse(State,<<"get key\r\n">>),
    {ok,<<"get key">>,_S1}=R,
    ok.

get_continue_test()->
    State=init(),
    {continue,S1}=parse(State,<<"get">>),
    R=parse(S1,<<" key\r\n">>),
    {ok,<<"get key">>,_}=R,
    ok.


delete_test()->
    State=init(),
    R=parse(State,<<"delete key\r\n">>),
    {ok,<<"delete key">>,_S1}=R,
    ok.

delete_continue_test()->
    State=init(),
    {continue,S1}=parse(State,<<"delete">>),
    R=parse(S1,<<" key\r\n">>),
    {ok,<<"delete key">>,_}=R,
    ok.

set_test()->
    State=init(),
    R=parse(State,<<"set key flags exptime bytes\r\ntest\r\n">>),
    {ok,_First,_Seconde,_}=R,
    ok.
set_continue_test()->
    State=init(),
    {continue,S1}=parse(State,<<"set key flags exptime bytes\r\n">>),
    R=parse(S1,<<"test\r\n">>),
    {ok,_First,Second,_}=R,
    ?assertEqual(Second,<<"test">>),
    ok.

-endif.

