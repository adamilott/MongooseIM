-module(domain_removal_SUITE).

%% API
-export([all/0,
         groups/0,
         init_per_suite/1,
         end_per_suite/1,
         init_per_group/2,
         end_per_group/2,
         init_per_testcase/2,
         end_per_testcase/2]).

-export([mam_pm_removal/1,
         mam_muc_removal/1]).

-import(mam_helper,
        [stanza_archive_request/2,
         wait_archive_respond/1,
         assert_respond_size/2,
         respond_messages/1,
         parse_forwarded_message/1]).

-import(distributed_helper, [mim/0,
                             require_rpc_nodes/1,
                             rpc/4]).

-include("mam_helper.hrl").
-include_lib("escalus/include/escalus.hrl").
-include_lib("escalus/include/escalus_xmlns.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("exml/include/exml_stream.hrl").

all() ->
    [{group, mam_removal}].

groups() ->
    [
     {mam_removal, [], [mam_pm_removal,
                        mam_muc_removal]}
    ].

domain() ->
    ct:get_config({hosts, mim, domain}).

%%%===================================================================
%%% Overall setup/teardown
%%%===================================================================
init_per_suite(Config) ->
    escalus:init_per_suite(Config).

end_per_suite(Config) ->
    escalus:end_per_suite(Config).

%%%===================================================================
%%% Group specific setup/teardown
%%%===================================================================
init_per_group(Group, Config) ->
    case mongoose_helper:is_rdbms_enabled(domain()) of
        true ->
            Config2 = dynamic_modules:save_modules(domain(), Config),
            rpc(mim(), gen_mod_deps, start_modules, [domain(), group_to_modules(Group)]),
            Config2;
        false ->
            {skip, require_rdbms}
    end.

end_per_group(_Groupname, Config) ->
    case mongoose_helper:is_rdbms_enabled(domain()) of
        true ->
            dynamic_modules:restore_modules(domain(), Config);
        false ->
            ok
    end,
    ok.

group_to_modules(mam_removal) ->
    MH = muc_light_helper:muc_host(),
    [{mod_mam_meta, [{backend, rdbms}, {pm, []}, {muc, [{host, MH}]}]},
     {mod_muc_light, []}].

%%%===================================================================
%%% Testcase specific setup/teardown
%%%===================================================================

init_per_testcase(TestCase, Config) ->
    escalus:init_per_testcase(TestCase, Config).

end_per_testcase(TestCase, Config) ->
    escalus:end_per_testcase(TestCase, Config).

%%%===================================================================
%%% Test Cases
%%%===================================================================

mam_pm_removal(Config) ->
    P = ?config(props, Config),
    F = fun(Alice, Bob) ->
        escalus:send(Alice, escalus_stanza:chat_to(Bob, <<"OH, HAI!">>)),
        escalus:wait_for_stanza(Bob),
        mam_helper:wait_for_archive_size(Alice, 1),
        mam_helper:wait_for_archive_size(Bob, 1),
        run_remove_domain(),
        mam_helper:wait_for_archive_size(Alice, 0),
        mam_helper:wait_for_archive_size(Bob, 0)
        end,
    escalus_fresh:story(Config, [{alice, 1}, {bob, 1}], F).

mam_muc_removal(Config0) ->
    F = fun(Config, Alice) ->
        Room = muc_helper:fresh_room_name(),
        MucHost = muc_light_helper:muc_host(),
        muc_light_helper:create_room(Room, MucHost, alice,
                                     [alice], Config, muc_light_helper:ver(1)),
        RoomAddr = <<Room/binary, "@", MucHost/binary>>,
        escalus:send(Alice, escalus_stanza:groupchat_to(RoomAddr, <<"text">>)),
        escalus:wait_for_stanza(Alice),
        mam_helper:wait_for_room_archive_size(MucHost, Room, 1),
        run_remove_domain(),
        mam_helper:wait_for_room_archive_size(MucHost, Room, 0),
        ok
        end,
    escalus_fresh:story_with_config(Config0, [{alice, 1}], F).

run_remove_domain() ->
    Acc = #{},
    rpc(mim(), ejabberd_hooks, run_fold,
        [remove_domain, domain(), Acc, [domain(), domain()]]).
