%% SPDX-License-Identifier: MIT
%%
%% The check of a lockfile against its project. The sandboxed build runs
%% it as `rebar3-purifier check DIR LOCKFILE` before rebar3, and the
%% interactive rebar3, `prefetch` and `publish` run it before they use the
%% lockfile. It stops with an error that names the command to run when the
%% lockfile is missing, malformed, of another format version or changed by
%% hand, when a file that defines the dependencies changed since the lock,
%% or when rebar.lock names a dependency that the lockfile has no download
%% for. nix/lib/lock.nix makes the same checks during evaluation.
-module(rp_check).

-export([check/2, current/1, missing/2]).

check(Dir, LockFile) ->
    current(#{
        root => Dir,
        lock_file => LockFile,
        rebar_lock => filename:join(Dir, "rebar.lock")
    }),
    ok.

%% The lockfile of Project, when it fits the project.
current(#{lock_file := LockFile, rebar_lock := RebarLock} = Project) ->
    Lock =
        case rp_util:read_lock(LockFile) of
            {ok, L} ->
                L;
            {error, enoent} ->
                rp_util:fail("~ts does not exist; run `rebar3-purifier lock`", [LockFile])
        end,
    Files = rp_util:definition_files(maps:get(root, Project), RebarLock),
    maps:get(<<"definitionHash">>, Lock) =:= rp_util:definition_hash(Project, Files) orelse
        rp_util:fail(
            "~ts is out of date, because one of ~ts changed since it was written; "
            "run `rebar3-purifier lock` and commit the lockfile",
            [LockFile, lists:join(", ", Files)]
        ),
    case missing(RebarLock, Lock) of
        [] ->
            Lock;
        Missing ->
            rp_util:fail(
                "rebar.lock names dependencies that ~ts has no download for: ~ts; "
                "run `rebar3-purifier lock` and commit the lockfile",
                [LockFile, lists:join(", ", Missing)]
            )
    end.

%% The dependencies in the rebar.lock RebarLock that have no download: a
%% Hex package without its outer checksum in rebar.lock and without a
%% tarball in Lock, or a git dependency without its checkout in Lock.
missing(RebarLock, Lock) ->
    {Deps, Ext} = rp_util:rebar_lock(RebarLock),
    Tarballs = [
        filename:basename(binary_to_list(P))
     || #{<<"path">> := P} <- maps:get(<<"hexTarballs">>, Lock)
    ],
    Revs = [binary_to_list(R) || #{<<"rev">> := R} <- maps:get(<<"git">>, Lock)],
    lists:usort(
        [
            binary_to_list(Name) ++ " " ++ binary_to_list(Vsn)
         || D <- Deps,
            {Name, Pkg, Vsn} <- [rp_util:hex_dep(D)],
            not maps:is_key(Name, Ext),
            not lists:member(binary_to_list(Pkg) ++ "-" ++ binary_to_list(Vsn) ++ ".tar", Tarballs)
        ] ++
            [
                binary_to_list(Name) ++ " (git " ++ binary_to_list(Rev) ++ ")"
             || {Name, _, _} = D <- Deps,
                {_, Rev} <- rp_util:locked_git_dep(D),
                not lists:member(binary_to_list(Rev), Revs)
            ]
    ).
