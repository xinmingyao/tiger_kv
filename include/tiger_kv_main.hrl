%%%----------------------------------------------------------------------
%%% OneCached (c) 2007 Process-one (http://www.process-one.net/)
%%% $Id$
%%%----------------------------------------------------------------------

-define(PORT, 11211).
-define(MAX_PACKET_SIZE, 300000).

-record(storage_command, {key, flags, exptime, bytes, data=""}).

-define(FSMOPTS, [{debug, [trace]}]).
%-define(FSMOPTS, []).

-define(INFO_MSG(Format, Args),
    error_logger:info_msg(Format, Args)).

-define(WARNING_MSG(Format, Args),
    error_logger:warning_msg(Format, Args)).

-define(ERROR_MSG(Format, Args),
    error_logger:error_msg(Format, Args)).

-define(CRITICAL_MSG(Format, Args),
    error_logger:error_msg("CRITICAL:~n"++Format, Args)).

%%%for edis
-define(INFO(Str, Args), lager:info(Str, Args)).
-define(DEBUG(Str, Args), lager:debug(Str, Args)).
-define(THROW(Str, Args), lager:error(Str, Args)).
-define(WARN(Str, Args), lager:warning(Str, Args)).
-define(ERROR(Str, Args), lager:error(Str, Args)).
-define(CDEBUG(F,Str, Args), lager:debug(Str, Args)).

%% Public types

-type option() :: {host, string()} | {port, integer()} | {database, string()} | {password, string()} | {reconnect_sleep, integer()}.
-type server_args() :: [option()].

-type return_value() :: undefined | binary() | [binary()].

-type pipeline() :: [iolist()].

-type channel() :: binary().

%% Continuation data is whatever data returned by any of the parse
%% functions. This is used to continue where we left off the next time
%% the user calls parse/2.
-type continuation_data() :: any().
-type parser_state() :: status_continue | bulk_continue | multibulk_continue.

%% Internal parser state. Is returned from parse/2 and must be
%% included on the next calls to parse/2.
-record(pstate, {
          state = undefined :: parser_state() | undefined,
          continuation_data :: continuation_data() | undefined
}).

-define(NL, "\r\n").

-define(SOCKET_OPTS, [binary, {active, once}, {packet, raw}, {reuseaddr, true}]).

%%Internal for mem parser, init->first_continue->storage_continue->first_continue
-type mem_parser_state() :: init | first_continue | storage_continue.
-record(memstate, {
          state = undefined :: mem_parser_state() | undefined,
          continuation_data :: continuation_data() | undefined,
	  storage_data
}).

