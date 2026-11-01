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

tmp_dir(Name) ->
    Dir = filename:join(os:getenv("TMPDIR", "/tmp"), "rp_tests-" ++ Name),
    rp_util:rm_rf(Dir),
    rp_util:ensure_dir(Dir),
    Dir.

%% A Hex tarball in the cache is a file entry at its cache path, at the
%% tarball URL of its repository, with its SHA-256.
hex_entries_test() ->
    Cache = tmp_dir("hex"),
    Packages = filename:join(Cache, "hex/hexpm/packages"),
    rp_util:ensure_dir(Packages),
    ok = file:write_file(filename:join(Packages, "jsx-3.1.0.tar"), <<"tarball">>),
    ok = file:write_file(filename:join(Packages, "jsx-3.1.0.etag"), <<"\"x\"">>),
    os:unsetenv("HEX_CDN"),
    ?assertEqual(
        [#{
            path => <<"hex/hexpm/packages/jsx-3.1.0.tar">>,
            url => <<"https://repo.hex.pm/tarballs/jsx-3.1.0.tar">>,
            mirrors => [],
            hash => rp_util:sri_sha256(<<"tarball">>)
        }],
        rp_lock:hex_entries(Cache, [])
    ),
    rp_util:rm_rf(Cache).

%% rebar.lock dependencies without a download in the lockfile, Hex and
%% git, are named.
missing_test() ->
    Dir = tmp_dir("missing"),
    ok = file:write_file(filename:join(Dir, "rebar.lock"), <<
        "{\"1.2.0\",\n"
        "[{<<\"jsx\">>,{pkg,<<\"jsx\">>,<<\"3.1.0\">>},0},\n"
        " {<<\"ranch\">>,{pkg,<<\"ranch\">>,<<\"1.8.0\">>},1},\n"
        " {<<\"meck\">>,{git,\"https://github.com/eproxus/meck.git\",{ref,\"abc\"}},0}]}.\n"
        "[].\n"
    >>),
    Lock = #{<<"artifacts">> => [#{<<"path">> => <<"hex/hexpm/packages/jsx-3.1.0.tar">>}]},
    ?assertEqual(["meck (git abc)", "ranch 1.8.0"], rp_check:missing(Dir, Lock)),
    rp_util:rm_rf(Dir).

%% rp_git rebuilds a repository that git clones by tag at the locked
%% commit, from a checkout with an executable, a symbolic link, nested and
%% empty directories, and it rejects a checkout that differs.
git_roundtrip_test() ->
    Tmp = tmp_dir("git"),
    Src = filename:join(Tmp, "src"),
    rp_util:ensure_dir(filename:join(Src, "sub/dir")),
    rp_util:ensure_dir(filename:join(Src, "empty")),
    ok = file:write_file(filename:join(Src, "a.txt"), <<"a\n">>),
    ok = file:write_file(filename:join(Src, "run"), <<"#!/bin/sh\n">>),
    ok = file:change_mode(filename:join(Src, "run"), 8#755),
    ok = file:write_file(filename:join(Src, "sub/dir/c.txt"), <<"c\n">>),
    ok = file:make_symlink("a.txt", filename:join(Src, "link")),
    Env = [
        {"GIT_AUTHOR_NAME", "t"}, {"GIT_AUTHOR_EMAIL", "t@example.com"},
        {"GIT_COMMITTER_NAME", "t"}, {"GIT_COMMITTER_EMAIL", "t@example.com"},
        {"GIT_AUTHOR_DATE", "2026-01-01T00:00:00Z"}, {"GIT_COMMITTER_DATE", "2026-01-01T00:00:00Z"},
        {"HOME", Tmp}
    ],
    Git = fun(Dir, Args) ->
        {0, Out} = rp_util:run_quiet("git", ["-c", "safe.directory=*" | Args], Dir, Env),
        string:trim(binary_to_list(Out))
    end,
    Git(Src, ["init", "-q"]),
    Git(Src, ["add", "-A"]),
    Git(Src, ["commit", "-q", "-m", "test"]),
    Rev = Git(Src, ["rev-parse", "HEAD"]),
    Object = base64:encode(list_to_binary(Git(Src, ["cat-file", "commit", Rev]) ++ "\n")),
    Checkout = filename:join(Tmp, "checkout"),
    {0, _} = rp_util:run_quiet("cp", ["-a", Src, Checkout], Tmp, []),
    rp_util:rm_rf(filename:join(Checkout, ".git")),
    Artifact = #{<<"git">> => #{
        <<"url">> => <<"https://example.com/t.git">>,
        <<"rev">> => list_to_binary(Rev),
        <<"commitObject">> => #{<<"object">> => Object, <<"gitlinks">> => []}
    }},
    Repo = filename:join(Tmp, "repo"),
    ok = rp_git:make_repo(Checkout, Repo, Artifact, #{<<"tags">> => [<<"v1">>]}),
    Git(Tmp, ["clone", "-q", "-b", "v1", "--single-branch", Repo, filename:join(Tmp, "clone")]),
    ?assertEqual(Rev, Git(filename:join(Tmp, "clone"), ["rev-parse", "HEAD"])),
    ok = file:write_file(filename:join(Checkout, "a.txt"), <<"changed\n">>),
    ?assertThrow({fail, _}, rp_git:make_repo(Checkout, filename:join(Tmp, "repo2"), Artifact, #{})),
    rp_util:rm_rf(Tmp).

sri_test() ->
    ?assertEqual(<<"sha256-47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=">>, rp_util:sri_sha256(<<>>)).
