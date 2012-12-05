-module(tiger_kv_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-compile([{parse_transform, lager_transform}]).

-define(HOST,'localhost').
-define(NODES,['n1@localhost','n2@localhost','n3@localhost']).


get_node_name()->
    N=atom_to_list(node()),
    {match,[_,{S1,E1}]}= re:run(N,"[^@](.*)@.*",[]),
    "/tmp/"++string:substr(N,S1,E1+1).
get_db()->	
    get_node_name()++".db".
get_log()->
    get_node_name()++".log".
get_zab()->
    get_node_name()++".zab".

stop()->
    slave:stop('n1@localhost'),
    slave:stop('n2@localhost'),
    slave:stop('n3@localhost').

start_lager()->
    Zab=get_zab(),
    Db=get_db(),

    os:cmd("rm -f "++ Zab),
    os:cmd("rm -f "++ Db),
    os:cmd("mkdir "++ Zab),
    Log=get_log(),
    os:cmd("rm -f "++ Log),
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend,error}
					  ,{lager_file_backend,[{Log,notice,10485760,"$D0",5}]}
					 ]),
    application:set_env(lager, error_logger_redirect, false),
 
    application:start(compiler),
    application:start(syntax_tools),
    application:start(lager),
    {ok,_}=tiger_global:start_link(),
    ok.


start_mem_slave(Name,Port)->
    slave:start(?HOST,Name,get_code_path()),
    N1=list_to_atom(atom_to_list(Name)++"@"++atom_to_list(?HOST)),
    rpc:cast(N1,?MODULE,start_mem_slave2,[Port]).

start_mem_slave2(Port)->
    Opt=[{bucket,1}],
    start_lager(),
    application:start(ranch),
    zabe_proposal_leveldb_backend:start_link(get_zab(),[]),
    ranch:start_listener(memcached,100,ranch_tcp,[{port,Port}],mem_frontend,[]),
    memcached_backend:start_link(?NODES,Opt,get_db()).


start_redis_slave(Name,Port)->
    {ok,_}=slave:start(?HOST,Name,get_code_path()),
    N1=list_to_atom(atom_to_list(Name)++"@"++atom_to_list(?HOST)),
    rpc:cast(N1,?MODULE,start_redis_slave2,[Port]).

start_redis_slave2(Port)->
    Opt=[{bucket,2}],
    start_lager(),
    application:start(ranch),
    {ok,_}=zabe_proposal_leveldb_backend:start_link(get_zab(),[]),
    ranch:start_listener(redis,100,ranch_tcp,[{port,Port}],redis_frontend,[]),
    C1=code:lib_dir(eredis_engine,'c_src/redis/redis.conf'),
    {ok,_}=redis_backend:start_link(?NODES,Opt,C1,get_db()).

get_code_path()->
    Ps=code:get_path(),
    lists:foldl(fun(A,Acc)->
			    " -pa "++A++ Acc end, " ",Ps).
init_per_suite(Config)->
    Config    
.


end_per_suite(Config)->

    Config.

init_per_testcase(_,Config)->

    Config
    .

end_per_testcase(_Config)->

    ok.



all()->
    [mem_crud,redis_crud].

redis_crud(_C)->
    stop(),
    start_redis_slave('n1',6379),
    timer:sleep(1500),
    {ok,C}=eredis:start_link(),
    {error,<<"not_ready">>}=eredis:q(C,["SET","foo","BAR"]),
    start_redis_slave('n2',6380),
    start_redis_slave('n3',6381),
    timer:sleep(2000),
    {ok,<<"OK">>}=eredis:q(C,["SET","foo","BAR"]),
    {ok,<<"BAR">>}=eredis:q(C,["GET","foo"]),
    {ok,<<"OK">>}=eredis:q(C,["DEL","foo"]),
    {ok,undefined}=eredis:q(C,["GET","foo"]),
    {ok,<<"PONG">>}=eredis:q(C,["PING"]),
    stop(),
    ok.
mem_crud(_Config)->
    stop(),
    start_mem_slave('n1',11211),
    timer:sleep(3000),
    merle:connect(),
    "NOT_READY"=merle:set("tt","aa"),
    "NOT_READY"=merle:delete("tt"),
   % "SERVER_ERROR not_ready"=merle:delete("tt"),
    start_mem_slave('n2',11212),
    start_mem_slave('n3',11213),
    timer:sleep(2500),    
    merle:set("a","aa"),
    "aa"=merle:getkey("a"),
    ok=merle:delete("a"),
    undefined=merle:getkey("a"),
    merle:set("bb",1023,1,"bb"),
    "bb"=merle:getkey("bb"),
    %test expire
    timer:sleep(1000),
    undefined=merle:getkey("bb"),
    stop(),
    ok 
    .



						

    

    


