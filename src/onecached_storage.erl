%%%----------------------------------------------------------------------
%%% OneCached (c) 2007 Process-one (http://www.process-one.net/)
%%% $Id$
%%%----------------------------------------------------------------------
-module(onecached_storage).
-author('jerome.sautret@process-one.net').
-vsn('$Revision$ ').
-modify('yaoxinming@gmail.com').
-compile([{parse_transform, lager_transform}]).
-export([
	 store_item/1,
	 has_item/1,
	 get_item/1,
	 delete_item/1
	 ]).

-include("tiger_kv_main.hrl").
-include("memcached_pb.hrl").

%%====================================================================
%% API functions
%%====================================================================

store_item(#storage_command{key=Key, flags=Flags, exptime=0, data=Data})->
  %%when Exptime > 60*60*24*30 -> % (Exptime > 30 days), it is an absolute Unix time
    memcached_backend:put(list_to_binary(Key),
			   memcached_pb:encode_onecached(#onecached{ 
				      flags=Flags,
				      exptime=0,
				      data=Data}));
store_item(#storage_command{key=Key, flags=Flags, exptime=Exptime, data=Data})->
  %%when Exptime > 60*60*24*30 -> % (Exptime > 30 days), it is an absolute Unix time
    {M, S, _MicroSecs}=now(),
    memcached_backend:put(list_to_binary(Key),
			   memcached_pb:encode_onecached(#onecached{ 
				      flags=Flags,
				      exptime=M*1000+S+Exptime,
				      data=Data})).

has_item(Key) ->
    case get_item(Key) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.


get_item(Key) ->
    case memcached_backend:get(list_to_binary(Key)) of
	{ok,D} ->
	    #onecached{exptime=Exptime,flags=Flags,data=Data}=memcached_pb:decode_onecached(D),
	    if
		Exptime=:=0-> 
		    {ok, {Flags,Data}};
		true -> 
		    {MegaSecs, Secs, _MicroSecs} = now(),
		    case Exptime > MegaSecs*1000+Secs of
			true ->
			    {ok,{Flags,Data}};
			false ->
			    %%not block,
			    erlang:spawn(?MODULE,delete_item,[Key]),
			    none
		    end
	    end;
	not_found ->none;
	R ->R
    end.

delete_item(Key) ->
    memcached_backend:delete(list_to_binary(Key)).
