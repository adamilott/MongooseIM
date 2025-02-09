%% @doc MongooseIM RDBMS backend for cets_discovery.
-module(mongoose_cets_discovery_rdbms).
-behaviour(cets_discovery).
-export([init/1, get_nodes/1]).

-include("mongoose_logger.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-type opts() :: #{cluster_name => binary(), node_name_to_insert => binary(), last_query_info => map(),
                  expire_time := non_neg_integer()}.
-type state() :: opts().

-spec init(opts()) -> state().
init(Opts = #{cluster_name := _, node_name_to_insert := _}) ->
    maps:merge(defaults(), Opts).

defaults() ->
    #{expire_time => 60 * 60 * 1, %% 1 hour in seconds
      last_query_info => #{}}.

-spec get_nodes(state()) -> {cets_discovery:get_nodes_result(), state()}.
get_nodes(State = #{cluster_name := ClusterName, node_name_to_insert := Node}) ->
    try
        case is_rdbms_running() of
            true ->
                try_register(ClusterName, Node, State);
            false ->
                skip
        end
    of
        {Num, Nodes, Info} ->
            mongoose_node_num:set_node_num(Num),
            {{ok, Nodes}, State#{last_query_info => Info}};
        skip ->
            {{error, rdbms_not_running}, State}
    catch Class:Reason:Stacktrace ->
            ?LOG_ERROR(#{what => discovery_failed_select, class => Class,
                         reason => Reason, stacktrace => Stacktrace}),
            {{error, Reason}, State}
    end.

is_rdbms_running() ->
    try mongoose_wpool:get_worker(rdbms, global) of
         {ok, _} -> true;
         _ -> false
    catch _:_ ->
         false
    end.

try_register(ClusterName, NodeBin, State) when is_binary(NodeBin), is_binary(ClusterName) ->
    prepare(),
    Timestamp = timestamp(),
    Node = binary_to_atom(NodeBin),
    {selected, Rows} = select(ClusterName),
    Zipped = [{binary_to_atom(DbNodeBin), Num, TS} || {DbNodeBin, Num, TS} <- Rows],
    {Nodes, Nums, _Timestamps} = lists:unzip3(Zipped),
    AlreadyRegistered = lists:member(Node, Nodes),
    NodeNum =
        case AlreadyRegistered of
            true ->
                 update_existing(ClusterName, NodeBin, Timestamp),
                 {value, {_, Num, _TS}} = lists:keysearch(Node, 1, Zipped),
                 Num;
            false ->
                 Num = next_free_num(lists:usort(Nums)),
                 %% Could fail with duplicate node_num reason.
                 %% In this case just wait for the next get_nodes call.
                 insert_new(ClusterName, NodeBin, Timestamp, Num),
                 Num
        end,
    RunCleaningResult = run_cleaning(ClusterName, Timestamp, Rows, State),
    %% This could be used for debugging
    Info = #{already_registered => AlreadyRegistered, timestamp => Timestamp,
             node_num => Num, last_rows => Rows, run_cleaning_result => RunCleaningResult},
    Nodes2 = skip_expired_nodes(Nodes, RunCleaningResult),
    {NodeNum, Nodes2, Info}.

skip_expired_nodes(Nodes, {removed, ExpiredNodes}) ->
    Nodes -- ExpiredNodes;
skip_expired_nodes(Nodes, {skip, _}) ->
    Nodes.

run_cleaning(ClusterName, Timestamp, Rows, State) ->
    Expired = [{DbNodeBin, Num, DbTS} || {DbNodeBin, Num, DbTS} <- Rows,
               is_expired(DbTS, Timestamp, State)],
    ExpiredNodes = [binary_to_atom(DbNodeBin) || {DbNodeBin, _Num, _TS} <- Expired],
    case Expired of
        [] ->
            {skip, nothing_expired};
        _ ->
            [delete_node_from_db(ClusterName, DbNodeBin) || {DbNodeBin, _Num, _TS} <- Expired],
            ?LOG_WARNING(#{what => cets_expired_nodes,
                           text => <<"Expired nodes are detected in discovery_nodes table">>,
                           expired_nodes => ExpiredNodes}),
            {removed, ExpiredNodes}
    end.

is_expired(DbTS, Timestamp, #{expire_time := ExpireTime}) when is_integer(DbTS) ->
    (Timestamp - DbTS) > ExpireTime. %% compare seconds

delete_node_from_db(ClusterName, Node) ->
    mongoose_rdbms:execute_successfully(global, cets_delete_node_from_db, [ClusterName, Node]).

prepare() ->
    T = discovery_nodes,
    mongoose_rdbms_timestamp:prepare(),
    mongoose_rdbms:prepare(cets_disco_select, T, [cluster_name], select()),
    mongoose_rdbms:prepare(cets_disco_insert_new, T,
                           [cluster_name, node_name, node_num, updated_timestamp], insert_new()),
    mongoose_rdbms:prepare(cets_disco_update_existing, T,
                           [updated_timestamp, cluster_name, node_name], update_existing()),
    mongoose_rdbms:prepare(cets_delete_node_from_db, T,
                           [cluster_name, node_name], delete_node_from_db()).

select() ->
    <<"SELECT node_name, node_num, updated_timestamp FROM discovery_nodes WHERE cluster_name = ?">>.

select(ClusterName) ->
    mongoose_rdbms:execute_successfully(global, cets_disco_select, [ClusterName]).

insert_new() ->
    <<"INSERT INTO discovery_nodes (cluster_name, node_name, node_num, updated_timestamp)"
      " VALUES (?, ?, ?, ?)">>.

insert_new(ClusterName, Node, Timestamp, Num) ->
    mongoose_rdbms:execute(global, cets_disco_insert_new, [ClusterName, Node, Num, Timestamp]).

update_existing() ->
    <<"UPDATE discovery_nodes SET updated_timestamp = ? WHERE cluster_name = ? AND node_name = ?">>.

delete_node_from_db() ->
    <<"DELETE FROM discovery_nodes WHERE cluster_name = ? AND node_name = ?">>.

update_existing(ClusterName, Node, Timestamp) ->
    mongoose_rdbms:execute(global, cets_disco_update_existing, [Timestamp, ClusterName, Node]).

%% in seconds
timestamp() ->
    % We could use Erlang timestamp os:system_time(second).
    % But we use the database server time as a central source of truth.
    mongoose_rdbms_timestamp:select().

%% Returns a next free node id based on the currently registered ids
next_free_num([]) ->
    0;
next_free_num([H | T = [E | _]]) when ((H + 1) =:= E) ->
    %% Sequential, ignore H
    next_free_num(T);
next_free_num([H | _]) ->
    H + 1.

-ifdef(TEST).

jid_to_opt_binary_test_() ->
    [?_assertEqual(0, next_free_num([])),
     ?_assertEqual(3, next_free_num([1, 2, 5])),
     ?_assertEqual(3, next_free_num([1, 2]))].

-endif.
