-module(memcached_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-compile([{parse_transform, lager_transform}]).
%-include("zabe_main.hrl").

init_per_suite(Config)->


    Config    
.



setup() ->
    application:load(lager), 
    application:set_env(lager, handlers, [{lager_console_backend, error}
					  ,{lager_file_backend,[{"/tmp/console.log",error,10485760,"$D0",5}]}
					 ]),
    application:set_env(lager, error_logger_redirect, false),
    application:start(compiler),
    application:start(syntax_tools),
    application:start(lager),
    application:start(sasl),
    application:start(erlbert),
    application:start(cowboy)
    .

local()->
    zabe_proposal_leveldb_backend:start_link("/tmp/p1.db",[]),
    cowboy:start_listener(redis,100,cowboy_tcp_transport,[{port,11211}],memcached_frontend,[]).

n1()->
    zabe_proposal_leveldb_backend:start_link("/tmp/p2.db",[]),
    cowboy:start_listener(redis,100,cowboy_tcp_transport,[{port,11212}],memcached_frontend,[]).
n2()->
    zabe_proposal_leveldb_backend:start_link("/tmp/p3.db",[]),
    cowboy:start_listener(redis,100,cowboy_tcp_transport,[{port,11213}],memcached_frontend,[]).

cleanup(_) ->
    application:stop(lager),
    application:stop(cowboy),
    error_logger:tty(true).

end_per_suite(Config)->
    cleanup(Config),
    Config.

init_per_testcase(_,Config)->

    Config
    .

end_per_testcase(Config)->

    ok.

-define(HOST,'localhost').


all()->
    [elect].

elect(Config)->
    os:cmd("rm -rf /tmp/*"),
    D1="/tmp/1.db",
    D2="/tmp/2.db",
    D3="/tmp/3.db",
    Op1=[{prefix,"mm"}],
    Op2=[{prefix,"mm"}],
    Op3=[{prefix,"mm"}],
    Nodes=[node(),'n1@localhost','n2@localhost'],
    Ps=code:get_path(),
    Arg=lists:foldl(fun(A,Acc)->
			    " -pa "++A++ Acc end, " ",Ps),
    slave:start(?HOST,n1,Arg),
    slave:start(?HOST,n2,Arg),
    setup(),
    ok=rpc:call('n1@localhost',?MODULE,setup,[]),
    ok=rpc:call('n2@localhost',?MODULE,setup,[]),
    
    local(),
    {ok,_}=rpc:call('n1@localhost',?MODULE,n1,[]),
    {ok,_}=rpc:call('n2@localhost',?MODULE,n2,[]),
    timer:sleep(300),

    {ok,_}=memcached_backend:start_link(Nodes,Op1,D1),    
    timer:sleep(200),
    merle:connect(),
    "SERVER_ERROR not_ready"=merle:set("tt","aa"),
    error_logger:info_msg("2222~p",merle:delete("tt")),
    "SERVER_ERROR not_ready"=merle:delete("tt"),
   % "SERVER_ERROR not_ready"=merle:delete("tt"),
    
    {ok,_}=rpc:call('n1@localhost',memcached_backend,start_link,[Nodes,Op2,D2]),
    {ok,_}=rpc:call('n2@localhost',memcached_backend,start_link,[Nodes,Op3,D3]),
    timer:sleep(800),    
    merle:set("a","aa"),
    "aa"=merle:getkey("a"),
    ok=merle:delete("a"),
    undefined=merle:getkey("a"),
    slave:stop('n1@localhost'),
    slave:stop('n2@localhost'),
    
    ok
    .



						

    

    


