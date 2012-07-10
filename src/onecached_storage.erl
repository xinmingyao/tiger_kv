%%%----------------------------------------------------------------------
%%% OneCached (c) 2007 Process-one (http://www.process-one.net/)
%%% $Id$
%%%----------------------------------------------------------------------

-module(onecached_storage).
-author('jerome.sautret@process-one.net').
-vsn('$Revision$ ').

% Handle all storage mechanisms (only mnesia for now).

-export([init/1,
	 store_item/2,
	 has_item/2,
	 get_item/2,
	 delete_item/2,
	 update_item_value/4,
	 flush_items/1]).

-include("tiger_kv_main.hrl").

-record(onecached, {key, flags, exptime, data}).

%%====================================================================
%% API functions
%%====================================================================

init(mnesia) ->
    ok.

store_item(mnesia, #storage_command{key=Key} = Command) when is_list(Key) ->
    store_item(mnesia, Command#storage_command{key=list_to_binary(Key)});
store_item(mnesia, #storage_command{key=Key, flags=Flags, exptime=Exptime, data=Data})
  when Exptime > 60*60*24*30 -> % (Exptime > 30 days), it is an absolute Unix time
    memcached_backend:put(binary_to_list(Key),
			   #onecached{key=Key,
				      flags=Flags,
				      exptime=Exptime,
				      data=list_to_binary(Data)});

store_item(mnesia, #storage_command{exptime=Exptime} = StorageCommand) ->
    % Exptime is an offset
    {MegaSecs, Secs, _MicroSecs} = now(),
    store_item(mnesia, StorageCommand#storage_command{exptime=Exptime + (MegaSecs*1000+Secs)}).

% return true if an item with Key is present
has_item(Storage, Key) when is_list(Key) ->
    has_item(Storage, list_to_binary(Key));
has_item(Storage, Key) ->
    case get_item(Storage, Key) of
	{ok, _} ->
	    true;
	_ ->
	    false
    end.

% Find the item with key Key, return
% {ok, {Flags, Data}}
% if found or
% none
% if not found or if the item has expired
% (in the later case, delete the item) or
% {error, Reason}
get_item(mnesia, Key) when is_list(Key) ->
    get_item(mnesia, list_to_binary(Key));
get_item(mnesia, Key) ->
    mnesia_get(Key, value).

delete_item(mnesia, Key) when is_list(Key) ->
    delete_item(mnesia, list_to_binary(Key));
delete_item(mnesia, Key) ->
    memcached_backend:delete(Key).


% Update the value of item with the result of
% Operation(ItemValue, Value)
% result value will be >=0
% return {ok, Value} if ok
update_item_value(mnesia, Key, Value, Operation) when is_list(Key) ->
    update_item_value(mnesia, list_to_binary(Key), Value, Operation);
update_item_value(mnesia, _Key, _Value, _Operation) ->
    exit(todo),
    ok.

flush_items(mnesia) ->
    exit(todo).

%%====================================================================
%% Internal functions for mnesia backend
%%====================================================================

% if Return == value, return
% {ok, {Flags, Value}}
% if Return == record, return
% {ok, #onecached}
% or none if not found
% LockType is dirty, read or write
mnesia_get(Key,Return) ->
    case memcached_backend:get(binary_to_list(Key)) of
	{ok,#onecached{exptime=0} = Item} ->
	    {ok, item_value(Return, Item)};
	{ok,#onecached{exptime=Exptime} = Item} ->
	    {MegaSecs, Secs, _MicroSecs} = now(),
	    case Exptime > MegaSecs*1000+Secs of
		true ->
		    {ok, item_value(Return, Item)};
		false ->
		    exit("todo delete"),
		    memcached_backend:delete(binary_to_list(Key)),
		    none
	    end;
	not_found ->none;
	R ->R
			
	
    end.
item_value(value, #onecached{flags = Flags, data = Data}) ->
    {Flags, Data};
item_value(record, Item) when is_record(Item, onecached) ->
    Item.

