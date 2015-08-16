-module(sidneycate).

-behaviour(gen_server).

%% Application API
-export([start/0,
         stop/0]).

%% API
-export([start_link/0]).

-export([join/1,
         leave/1,
         bailout/1]).

%% gen_server callbacks
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {self            = undefined :: node(),
                cluster         = undefined :: sets:set(node()),
                c_nodes_queue   = undefined :: sets:set(node()),
                d_nodes_queue   = undefined :: sets:set(node()),
                sync_timer      = undefined :: reference()
}).

%% ===================================================================
%% Application API
%% ===================================================================

start() ->
    application:ensure_all_started(?MODULE).

stop() ->
    ok.

%% ===================================================================
%% API functions
%% ===================================================================

-spec join(node() | [node()] | sets:set(node())) -> 'ok'.
join([]) ->
    ok;

join(Node) when is_atom(Node) ->
    join([Node]);

join(Nodes) when is_list(Nodes) ->
    join(set(Nodes));

join(Nodes) ->
    gen_server:abcast(?MODULE, {join, Nodes}),
    ok.

-spec leave(node() | [node()] | sets:set(node())) -> 'ok'.
leave([]) ->
    ok;

leave(Node) when is_atom(Node) ->
    leave([Node]);

leave(Nodes) when is_list(Nodes) ->
    leave(set(Nodes));

leave(Nodes) ->
    gen_server:abcast(?MODULE, {leave, Nodes}),
    ok.

-spec bailout(node() | [node()] | sets:set(node())) -> 'ok'.
bailout([]) ->
    ok;

bailout(Node) when is_atom(Node) ->
    bailout([Node]);

bailout(Nodes) when is_list(Nodes) ->
    bailout(set(Nodes));

bailout(Nodes) ->
    gen_server:abcast(?MODULE, {bailout, Nodes}),
    ok.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ===================================================================
%% gen_server callbacks
%% ==================================================================

init([]) ->
    promiscuous(),
    {ok, #state{self = node(), cluster = sets:new(), c_nodes_queue = sets:new(), d_nodes_queue = sets:new(), sync_timer = synchronize(1)}}.

handle_call(_Request, _From, State) ->
    {reply, ok, State}.

handle_cast({join, Nodes}, #state{self = Self, cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes} = State) ->
    {SuccessNodes, FailNodes} = join_nodes(join_candidates(Self, Cluster, Nodes)),
    FailNodes =/= [] andalso lager:error("Establishing connection with nodes ~s failed", [stringify(FailNodes)]),
    {noreply, State#state{cluster = add(FailNodes, add(SuccessNodes, Cluster)), c_nodes_queue = add(FailNodes, del(SuccessNodes, CNodes)), d_nodes_queue = del(SuccessNodes, DNodes)}};

handle_cast({leave, Nodes}, #state{self = Self, cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes} = State) ->
    {SuccessNodes, FailNodes} = leave_nodes(leave_candidates(Self, Cluster, Nodes)),
    FailNodes =/= [] andalso lager:error("Terminating connection with nodes ~s failed", [stringify(FailNodes)]),
    {noreply, State#state{cluster = del(SuccessNodes, add(FailNodes, Cluster)), c_nodes_queue = del(SuccessNodes, CNodes), d_nodes_queue = add(FailNodes, del(SuccessNodes, DNodes))}};

handle_cast({bailout, Nodes}, #state{self = Self, cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes} = State) ->
    {SuccessNodes, FailNodes} = bailout_nodes(leave_candidates(Self, Cluster, Nodes)),
    FailNodes =/= [] andalso lager:error("Terminating connection with nodes ~s failed", [stringify(FailNodes)]),
    {noreply, State#state{cluster = del(SuccessNodes, add(FailNodes, Cluster)), c_nodes_queue = del(SuccessNodes, CNodes), d_nodes_queue = add(FailNodes, del(SuccessNodes, DNodes))}};

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({nodeup, Node, Reason}, #state{cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes} = State) ->
    lager:info("Connection with node ~s established", [stringify(Node)]),
    in(Node, CNodes) orelse not in(Node, Cluster) andalso join(Node),
    in(Node, DNodes) andalso leave(Node),
    {noreply, State#state{c_nodes_queue = del(Node, CNodes)}};

handle_info({nodedown, Node, Reason}, #state{cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes} = State) ->
    lager:info("Connection with node ~s terminated", [stringify(Node)]),
    in(Node, Cluster) andalso not in(Node, DNodes) andalso join(Node),
    in(Node, DNodes) andalso leave(Node),
    {noreply, State#state{d_nodes_queue = del(Node, DNodes)}};

handle_info(synchronize, #state{cluster = Cluster, c_nodes_queue = CNodes, d_nodes_queue = DNodes, sync_timer = TRef} = State) ->
    catch erlang:cancel_timer(TRef),
    join(CNodes),
    leave(DNodes),
    {noreply, State#state{sync_timer = synchronize(len(Cluster) + 1)}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% ===================================================================
%% Internal functions
%% ===================================================================

promiscuous() ->
    ok = net_kernel:monitor_nodes(true, [nodedown_reason]).

synchronize(N) ->
    random:seed(erlang:system_time()),
    Interval = random:uniform(net_kernel:get_net_ticktime() * N),
    erlang:send_after(Interval * 1000, self(), synchronize).

-spec join_nodes(sets:set(node())) -> {[node()], [node()]}.
join_nodes(Nodes) ->
    connectiviy(fun(Node) -> net_kernel:connect(Node) end, list(Nodes), [], []).

-spec leave_nodes(sets:set(node())) -> {[node()], [node()]}.
leave_nodes(Nodes) ->
    connectiviy(fun(Node) -> net_kernel:disconnect(Node) end, list(Nodes), [], []).

-spec bailout_nodes(sets:set(node())) -> {[node()], [node()]}.
bailout_nodes(Nodes) ->
    connectiviy(fun(Node) -> net_kernel:disconnect(Node), in(Node, set(nodes())) end, list(Nodes), [], []).

-spec connectiviy(fun((node()) -> boolean()), [node()], [node()], [node()]) -> {[node()], [node()]}.
connectiviy(F, [], [], []) ->
    {[], []};

connectiviy(F, [], SuccessNodes, FailNodes) ->
    {SuccessNodes, FailNodes};

connectiviy(F, [Node | Nodes], SuccessNodes, FailNodes) ->
    case F(Node) of
        true ->
            connectiviy(F, Nodes, [Node | SuccessNodes], FailNodes);
        false ->
            connectiviy(F, Nodes, SuccessNodes, [Node | FailNodes])
    end.

-spec join_nodes(node(), sets:set(node()), sets:set(node())) -> sets:set(node()).
join_candidates(Self, Cluster, Nodes) ->
    del(Self, Nodes).

-spec leave_nodes(node(), sets:set(node()), sets:set(node())) -> sets:set(node()).
leave_candidates(Self, Cluster, Nodes) ->
    case in(Self, Nodes) of
        true ->
            Cluster;
        false ->
            intersection(Cluster, Nodes)
    end.


set(Xs) ->
    sets:from_list(Xs).

list(Xs) ->
    sets:to_list(Xs).

len(Xs) ->
    sets:size(Xs).

in(X, Xs) ->
    sets:is_element(X, Xs).

add(X, Xs) when is_atom(X) ->
    sets:add_element(X, Xs);

add(Ys, Xs) when is_list(Ys) ->
    sets:union(Xs, set(Ys));

add(Ys, Xs) ->
    sets:union(Xs, Ys).

del(X, Xs) when is_atom(X) ->
    sets:del_element(X, Xs);

del(Ys, Xs) when is_list(Ys) ->
    sets:subtract(Xs, set(Ys));

del(Ys, Xs) ->
    sets:subtract(Xs, Ys).

intersection(Ys, Xs) ->
    sets:intersection(Ys, Xs).


stringify(X) when is_atom(X) ->
    stringify([X]);

stringify([X | Xs]) when is_list(Xs) ->
    lists:foldl(fun(X, Acc) -> ["'", atom_to_list(X), "' ," | Acc] end, ["'", atom_to_list(X), "'"], Xs).

