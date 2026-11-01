%% SPDX-License-Identifier: MIT
%%
%% Unit tests of the parts of rebar3-purifier that need neither rebar3 nor
%% the network. The build of the command runs them.
-module(rp_tests).

-include_lib("eunit/include/eunit.hrl").

https_url_test_() ->
    [
        ?_assertEqual("https://github.com/o/r.git", rp_lock:https_url("git@github.com:o/r.git")),
        ?_assertEqual("https://github.com/o/r.git", rp_lock:https_url("ssh://git@github.com/o/r.git")),
        ?_assertEqual("https://example.com/o/r", rp_lock:https_url("ssh://example.com:2222/o/r")),
        ?_assertEqual("https://github.com/o/r", rp_lock:https_url("git://github.com/o/r")),
        ?_assertEqual("https://github.com/o/r", rp_lock:https_url("https://github.com/o/r"))
    ].

quote_test_() ->
    [
        ?_assertEqual("'plain'", lists:flatten(rp_wrapper:quote("plain"))),
        ?_assertEqual("'it'\\''s'", lists:flatten(rp_wrapper:quote("it's")))
    ].

repo_url_test_() ->
    {setup,
     fun() ->
         Saved = [{V, os:getenv(V)} || V <- ["HEX_CDN", "HEX_MIRROR"]],
         os:unsetenv("HEX_CDN"),
         os:unsetenv("HEX_MIRROR"),
         Saved
     end,
     fun(Saved) ->
         [case Value of false -> os:unsetenv(V); _ -> os:putenv(V, Value) end || {V, Value} <- Saved]
     end,
     fun(_) ->
         Config = [{hex, [{repos, [#{name => <<"internal">>, repo_url => <<"https://hex.example.com/">>}]}]}],
         [
             ?_assertEqual(<<"https://repo.hex.pm">>, rp_lock:repo_url("hexpm", [])),
             ?_assertEqual(<<"https://repo.hex.pm/repos/acme">>, rp_lock:repo_url("hexpm:acme", [])),
             ?_assertEqual(<<"https://hex.example.com">>, rp_lock:repo_url("internal", Config)),
             ?_test(begin
                 os:putenv("HEX_CDN", "https://mirror.example.com/"),
                 ?assertEqual(<<"https://mirror.example.com">>, rp_lock:repo_url("hexpm", [])),
                 os:unsetenv("HEX_CDN")
             end)
         ]
     end}.

%% The lockfile's JSON has sorted keys and fixed indentation, so a relock
%% that finds the same downloads writes the same bytes.
write_json_test() ->
    File = filename:join(os:getenv("TMPDIR", "/tmp"), "rp_tests.json"),
    rp_util:write_json(File, #{b => [1, #{d => true, c => <<"x">>}], a => #{}}),
    {ok, Bin} = file:read_file(File),
    ok = file:delete(File),
    ?assertEqual(
        <<"{\n  \"a\": {},\n  \"b\": [\n    1,\n    {\n      \"c\": \"x\",\n      \"d\": true\n    }\n  ]\n}\n">>,
        Bin
    ).

sri_test() ->
    ?assertEqual(<<"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=">>, rp_util:sri_sha256(<<>>)).
