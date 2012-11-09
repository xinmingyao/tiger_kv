-module(tiger_kv_SUITE).
-compile(export_all).
-include_lib("common_test/include/ct.hrl").
-compile([{parse_transform, lager_transform}]).
%-include("zabe_main.hrl").


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
start(Opts)->
    
    Zab=get_zab(),
    Db=get_db(),

    os:cmd("rm -f "++ Zab),
    os:cmd("rm -f "++ Db),
    
    start_lager(),
    timer:sleep(2),
    zabe_proposal_leveldb_backend:start_link(Zab,[]),
    Op1=[{proposal_dir,Zab}|Opts],
    zabe_learn_leveldb:start_link(?NODES,Op1,Db).


start_lager()->
    Log=get_log(),
    os:cmd("rm -f "++ Log),
    application:load(lager),
    application:set_env(lager, handlers, [{lager_console_backend,error}
					  ,{lager_file_backend,[{Log,debug,10485760,"$D0",5}]}
					 ]),
    application:set_env(lager, error_logger_redirect, false),
 
    application:start(compiler),
    application:start(syntax_tools),
    application:start(lager).


start_mem_slave(Name,Port)->
    slave:start(?HOST,Name,get_code_path()),
    N1=list_to_atom(atom_to_list(Name)++"@"++atom_to_list(?HOST)),
    rpc:cast(N1,?MODULE,start_mem_slave2,[Port]).

start_mem_slave2(Port)->
    Opt=[{bucket,1}],
    start_lager(),
    application:start(ranch),
    zabe_proposal_leveldb_backend:start_link(get_zab(),[]),
    ranch:start_listener(memcached,100,ranch_tcp,[{port,Port}],memcached_frontend,[]),
    memcached_backend:start_link(?NODES,Opt,get_db()).


start_redis_slave(Name,Port)->
    slave:start(?HOST,Name,get_code_path()),
    N1=list_to_atom(atom_to_list(Name)++"@"++atom_to_list(?HOST)),
    rpc:cast(N1,?MODULE,start_redis_slave2,[Port]).

start_redis_slave2(Port)->
    Opt=[{bucket,2}],
    start_lager(),
    application:start(ranch),
    zabe_proposal_leveldb_backend:start_link(get_zab(),[]),
    ranch:start_listener(redis,100,ranch_tcp,[{port,Port}],edis_client,[]),
    C1=code:lib_dir(eredis_engine,'c_src/redis/redis.conf'),
    edis_db:start_link(?NODES,Opt,C1,get_db()).

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
    start_redis_slave('n2',6380),
    start_redis_slave('n3',6381),
    timer:sleep(2000),
    {ok,C}=eredis:start_link(),
    {ok,<<"OK">>}=eredis:q(C,["SET","foo","BAR"]),
    {ok,<<"BAR">>}=eredis:q(C,["GET","foo"]),
   % stop(),
    ok.
mem_crud(_Config)->
    stop(),
    start_mem_slave('n1',11211),
    timer:sleep(1000),
    merle:connect(),
    "SERVER_ERROR not_ready"=merle:set("tt","aa"),
    "SERVER_ERROR not_ready"=merle:delete("tt"),
   % "SERVER_ERROR not_ready"=merle:delete("tt"),
    start_mem_slave('n2',11212),
    start_mem_slave('n3',11213),
    timer:sleep(2500),    
    merle:set("a","aa"),
    "aa"=merle:getkey("a"),
    ok=merle:delete("a"),
    undefined=merle:getkey("a"),
    stop()
   
    .



						

    

    


