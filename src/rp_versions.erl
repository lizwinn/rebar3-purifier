%% SPDX-License-Identifier: MIT
%%
%% `rebar3-purifier pin-versions DIR LOCKFILE`, which the sandboxed build
%% runs before rebar3. An application whose .app.src takes its version
%% from version control, as `{vsn, git}` does, cannot compute it in the
%% sandbox, which has no .git directory. The lock run recorded the version
%% rebar3 computed for each of the project's applications, so this writes
%% that version into the build's copy of each such .app.src.
-module(rp_versions).

-export([pin/2]).

pin(Dir, LockFile) ->
    {ok, Lock} = rp_util:read_lock(LockFile),
    Apps = maps:get(<<"apps">>, maps:get(<<"outputs">>, Lock)),
    lists:foreach(fun(App) -> pin_app(Dir, App) end, Apps).

pin_app(Dir, #{<<"name">> := Name, <<"version">> := Version, <<"dir">> := AppDir}) ->
    Src = filename:join([Dir, AppDir, "src", <<Name/binary, ".app.src">>]),
    case file:consult(Src) of
        {ok, [{application, App, Props}]} ->
            case proplists:get_value(vsn, Props) of
                V when is_list(V) ->
                    ok;
                _ ->
                    Pinned = lists:keystore(vsn, 1, Props, {vsn, binary_to_list(Version)}),
                    ok = file:write_file(Src, io_lib:format("~p.~n", [{application, App, Pinned}])),
                    io:format(
                        "rebar3-purifier: ~ts takes version ~ts, recorded by the lock run~n",
                        [Name, Version]
                    )
            end;
        _ ->
            ok
    end.
