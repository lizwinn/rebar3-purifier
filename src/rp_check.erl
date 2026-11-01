%% SPDX-License-Identifier: MIT
%%
%% `rebar3-purifier check DIR LOCKFILE`, which the sandboxed build runs
%% before rebar3. It stops the build with an error that says what to do
%% when the lockfile does not fit the source: when a file that defines the
%% dependencies changed since the lock, or when rebar.lock names a
%% dependency the lockfile has no download for.
-module(rp_check).

-export([check/2, missing/2]).

check(Dir, LockFile) ->
    Lock =
        case rp_util:read_lock(LockFile) of
            {ok, L} ->
                L;
            {error, version} ->
                rp_util:fail(
                    "~ts was written by another rebar3-purifier version; "
                    "run `rebar3-purifier relock` and commit the lockfile",
                    [LockFile]
                )
        end,
    Files = rp_util:definition_files(Dir),
    maps:get(<<"definitionHash">>, Lock) =:= rp_util:definition_hash(Dir, Files) orelse
        rp_util:fail(
            "the lockfile is out of date: ~ts changed since it was written; "
            "run `rebar3-purifier lock` in the project and commit rebar3-purifier.lock.json",
            [lists:join(", ", Files)]
        ),
    case missing(Dir, Lock) of
        [] ->
            ok;
        Missing ->
            rp_util:fail(
                "rebar.lock names dependencies the lockfile has no download for: ~ts; "
                "run `rebar3-purifier relock` and commit rebar3-purifier.lock.json",
                [lists:join(", ", Missing)]
            )
    end.

%% The dependencies in Dir's rebar.lock that Lock has no entry for: a Hex
%% package without its tarball, or a git dependency without its commit.
missing(Dir, Lock) ->
    Paths = [maps:get(<<"path">>, A) || A <- maps:get(<<"artifacts">>, Lock)],
    Tarballs = [
        filename:basename(binary_to_list(P))
     || P <- Paths, lists:prefix("hex/", binary_to_list(P))
    ],
    Commits = [
        filename:basename(binary_to_list(P))
     || P <- Paths, lists:prefix("git/", binary_to_list(P))
    ],
    lists:usort(
        [
            binary_to_list(Name) ++ " " ++ binary_to_list(Vsn)
         || {Name, {pkg, Pkg, Vsn}, _} <- deps(Dir),
            not lists:member(binary_to_list(Pkg) ++ "-" ++ binary_to_list(Vsn) ++ ".tar", Tarballs)
        ] ++
            [
                binary_to_list(Name) ++ " (git " ++ Rev ++ ")"
             || {Name, Source, _} <- deps(Dir),
                {ref, Rev} <- [git_ref(Source)],
                not lists:member(Rev, Commits)
            ]
    ).

git_ref({git, _, Ref}) -> Ref;
git_ref({git_subdir, _, Ref, _}) -> Ref;
git_ref(_) -> none.

deps(Dir) ->
    case rp_util:consult(filename:join(Dir, "rebar.lock")) of
        [{_Version, Deps} | _] when is_list(Deps) -> [pkg3(D) || D <- Deps];
        [Deps] when is_list(Deps) -> [pkg3(D) || D <- Deps];
        _ -> []
    end.

%% A Hex dependency in rebar.lock is {pkg, Name, Vsn} or, for one renamed
%% in rebar.config, {pkg, Pkg, Vsn} under another name.
pkg3({Name, {pkg, Pkg, Vsn, _, _}, Level}) -> {Name, {pkg, Pkg, Vsn}, Level};
pkg3({Name, {pkg, Pkg, Vsn, _}, Level}) -> {Name, {pkg, Pkg, Vsn}, Level};
pkg3(Dep) -> Dep.
