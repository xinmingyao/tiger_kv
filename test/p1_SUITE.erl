-module('p1_SUITE').
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-compile([{parse_transform, lager_transform}]).
%-include("zabe_main.hrl").


init_per_suite(Config)->


    Config    
.



setup() ->
%    error_logger:tty(false),
    application:load(lager), 
    application:set_env(lager, handlers, [{lager_console_backend, info}
					  ,{lager_file_backend,[{"/tmp/console.log",info,10485760,"$D0",5}]}
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
    cowboy:start_listener(bert,100,cowboy_tcp_transport,[{port,11211}],memcached_frontend,[]).

n1()->
    cowboy:start_listener(bert,100,cowboy_tcp_transport,[{port,11212}],memcached_frontend,[]).
n2()->
    cowboy:start_listener(bert,100,cowboy_tcp_transport,[{port,11213}],memcached_frontend,[]).

cleanup(_) ->
    application:stop(lager),
    error_logger:tty(true).

end_per_suite(Config)->

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
    D1="/tmp/1.db",
    D2="/tmp/2.db",
    D3="/tmp/3.db",
    Op1=[{proposal_dir,"/tmp/p1.db"}],
    Op2=[{proposal_dir,"/tmp/p2.db"}],
    Op3=[{proposal_dir,"/tmp/p3.db"}],
    Nodes=[node(),'n1@localhost','n2@localhost'],
    D1="/tmp/1.db",
    D2="/tmp/2.db",
    D3="/tmp/3.db",
    Op1=[{proposal_dir,"/tmp/p1.db"}],
    Op2=[{proposal_dir,"/tmp/p2.db"}],
    Op3=[{proposal_dir,"/tmp/p3.db"}],
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
    timer:sleep(800),
lager:info("4444444444444444444"),
    {ok,_}=zabe_learn_leveldb:start_link(Nodes,Op1,D1),    
    
    {ok,_}=rpc:call('n1@localhost',zabe_learn_leveldb,start_link,[Nodes,Op2,D2]),

    {ok,_}=rpc:call('n2@localhost',zabe_learn_leveldb,start_link,[Nodes,Op3,D3]),
    timer:sleep(800),
    ok
    .



						

    

    


