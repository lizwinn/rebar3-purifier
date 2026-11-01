%% SPDX-License-Identifier: MIT
%%
%% The git repositories rebar3 clones its git dependencies from.
%%
%% rebar3 clones a git dependency and checks out a commit, a tag or a
%% branch, so it needs a repository that holds the locked commit under its
%% own hash. A checkout with its .git directory does not hash the same way
%% twice, since git packs objects differently from run to run, so the
%% lockfile pins a plain checkout and records the raw commit object and
%% the submodule entries of its tree. The shared purifier library rebuilds
%% a shallow .git directory from those and checks that the commit hashes to
%% the locked revision. This module reads the commit object and submodule
%% entries during the lock run, and in the cache tree makes a bare
%% repository of the rebuilt .git directory, with the tags and branches the
%% lock run saw, since rebar3 clones a tag or a branch by name.
-module(rp_git).

-export([bare_repo/3, commit_info/2]).

%% Writes a bare repository at Dest from the .git directory DotGit, with
%% the tags and branches that Source, the entry's record in gitSources,
%% names. Source is an empty map for a repository rebar3 clones by commit
%% only.
bare_repo(DotGit, Dest, Source) ->
    {0, _} = rp_util:run_quiet("cp", ["-R", "--no-preserve=mode", DotGit, Dest], DotGit, []),
    Rev = string:trim(rev(Dest)),
    ok = file:write_file(
        filename:join(Dest, "config"),
        "[core]\n\trepositoryformatversion = 0\n\tbare = true\n"
    ),
    rp_util:rm_rf(filename:join(Dest, "index")),
    [
        write_ref(Dest, "refs/heads/" ++ binary_to_list(B), Rev)
     || B <- maps:get(<<"branches">>, Source, [])
    ],
    [
        write_ref(Dest, "refs/tags/" ++ binary_to_list(T), Rev)
     || T <- maps:get(<<"tags">>, Source, [])
    ],
    ok.

%% The commit HEAD names, through its branch.
rev(GitDir) ->
    {ok, <<"ref: ", Ref/binary>>} = file:read_file(filename:join(GitDir, "HEAD")),
    {ok, Rev} = file:read_file(filename:join(GitDir, string:trim(Ref))),
    binary_to_list(Rev).

write_ref(Dest, Ref, Rev) ->
    File = filename:join(Dest, Ref),
    rp_util:ensure_dir(filename:dirname(File)),
    ok = file:write_file(File, [Rev, "\n"]).

%% For the lock run: the raw commit object of Rev in the repository at Url,
%% base64-encoded, and the submodule entries of its tree, as the shared
%% library's commitObject records them. It fetches the one commit into a
%% scratch repository.
commit_info(Url, Rev) ->
    Work = filename:join(
        os:getenv("TMPDIR", "/tmp"),
        "rebar3-purifier-" ++ os:getpid() ++ "-" ++ Rev
    ),
    rp_util:rm_rf(Work),
    rp_util:ensure_dir(Work),
    try
        {0, _} = rp_util:run_quiet("git", ["init", "-q", "--bare", Work], Work, []),
        case
            rp_util:run_quiet("git", ["-C", Work, "fetch", "-q", "--depth=1", Url, Rev], Work, [])
        of
            {0, _} ->
                ok;
            {S, Out} ->
                rp_util:fail("git fetch ~ts ~ts failed with exit status ~b:~n~ts", [
                    Url, Rev, S, Out
                ])
        end,
        {0, Commit} = rp_util:run_quiet("git", ["-C", Work, "cat-file", "commit", Rev], Work, []),
        {0, Tree} = rp_util:run_quiet("git", ["-C", Work, "ls-tree", "-r", "-z", Rev], Work, []),
        Gitlinks = [
            #{path => Path, rev => Sha}
         || Line <- binary:split(Tree, <<0>>, [global]),
            [<<"160000 commit ", Sha:40/binary>>, Path] <- [binary:split(Line, <<"\t">>)]
        ],
        {base64:encode(Commit), Gitlinks}
    after
        rp_util:rm_rf(Work)
    end.
