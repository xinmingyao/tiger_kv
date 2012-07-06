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

