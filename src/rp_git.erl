%% SPDX-License-Identifier: MIT
%%
%% A git repository rebar3 can clone, rebuilt from a plain checkout.
%%
%% rebar3 clones a git dependency and checks out a commit, a tag or a
%% branch, so it needs a repository that holds the locked commit under its
%% own hash. A checkout with its .git directory does not hash the same way
%% twice, since git packs objects differently from run to run. A plain
%% checkout does, so the lockfile pins the plain checkout and records the
%% raw commit object beside it. This module writes the checkout's files
%% and directories as git objects, writes the recorded commit object, and
%% checks that the commit hashes to the locked revision, which proves that
%% the repository holds exactly the locked commit. The commit's parents are
%% left out, and the repository's `shallow` file says so, as a shallow
%% clone's does. The tags and branches the lock run saw point at the
%% commit.
-module(rp_git).

-include_lib("kernel/include/file.hrl").

-export([make_repo/4, commit_info/2]).

%% Writes a bare repository at Dest from the checkout at Checkout, for the
%% git entry Artifact of a lockfile, with the commit object it records.
%% Source is the entry's record in gitSources, with the tags, branches and
%% submodule entries, or an empty map.
make_repo(Checkout, Dest, #{<<"git">> := Git}, Source) ->
    Rev = binary_to_list(maps:get(<<"rev">>, Git)),
    Url = maps:get(<<"url">>, Git),
    Commit = base64:decode(maps:get(<<"commitObject">>, Git)),
    Gitlinks = maps:from_list([
        {P, hex_to_raw(R)}
     || #{<<"path">> := P, <<"rev">> := R} <- maps:get(<<"gitlinks">>, Source, [])
    ]),
    rp_util:ensure_dir(filename:join(Dest, "objects")),
    Tree = write_tree(Checkout, <<>>, Gitlinks, Dest),
    TreeHex = hex(Tree),
    case Commit of
        <<"tree ", TreeLine:40/binary, "\n", _/binary>> when TreeLine =:= TreeHex ->
            ok;
        _ ->
            rp_util:fail("the checkout of ~ts at ~ts does not reproduce the tree of its commit (got ~ts)",
                         [Url, Rev, TreeHex])
    end,
    CommitSha = write_object(Dest, "commit", Commit),
    hex(CommitSha) =:= list_to_binary(Rev) orelse
        rp_util:fail("the recorded commit object of ~ts hashes to ~ts, not ~ts",
                     [Url, hex(CommitSha), Rev]),
    Branches = [binary_to_list(B) || B <- maps:get(<<"branches">>, Source, [])],
    Tags = [binary_to_list(T) || T <- maps:get(<<"tags">>, Source, [])],
    Head = case Branches of [B | _] -> B; [] -> "rebar3-purifier" end,
    [write_ref(Dest, "refs/heads/" ++ B, Rev) || B <- lists:usort([Head | Branches])],
    [write_ref(Dest, "refs/tags/" ++ T, Rev) || T <- Tags],
    ok = file:write_file(filename:join(Dest, "HEAD"), ["ref: refs/heads/", Head, "\n"]),
    ok = file:write_file(filename:join(Dest, "shallow"), [Rev, "\n"]),
    ok = file:write_file(filename:join(Dest, "config"),
                         "[core]\n\trepositoryformatversion = 0\n\tbare = true\n"),
    rp_util:ensure_dir(filename:join(Dest, "refs/tags")),
    ok.

write_ref(Dest, Ref, Rev) ->
    File = filename:join(Dest, Ref),
    rp_util:ensure_dir(filename:dirname(File)),
    ok = file:write_file(File, [Rev, "\n"]).

%% The tree object of the directory Rel under Root, written to Dest, and
%% its raw hash. Entries sort the way git sorts them: by name, with a
%% directory compared as if its name ended in "/". Empty directories have
%% no tree in git and are left out; a path the commit holds as a submodule
%% is its recorded gitlink.
write_tree(Root, Rel, Gitlinks, Dest) ->
    {ok, Names} = file:list_dir_all(filename:join(Root, Rel)),
    Entries = lists:filtermap(
        fun(Name) -> entry(Root, join(Rel, Name), Name, Gitlinks, Dest) end,
        [bin(N) || N <- Names, not (Rel =:= <<>> andalso bin(N) =:= <<".git">>)]
    ),
    Sorted = lists:sort(fun({_, A, _}, {_, B, _}) -> A =< B end, Entries),
    Data = [[Mode, " ", Name, 0, Sha] || {Mode, _, {Name, Sha}} <- Sorted],
    write_object(Dest, "tree", iolist_to_binary(Data)).

%% A tree entry: its mode, its sort key and its name and hash. Names are
%% the bytes of the file names, which git sorts byte by byte.
entry(Root, Rel, Name, Gitlinks, Dest) ->
    case maps:find(Rel, Gitlinks) of
        {ok, Sha} ->
            {true, {"160000", Name, {Name, Sha}}};
        error ->
            Path = filename:join(Root, Rel),
            {ok, #file_info{type = Type, mode = Mode}} = file:read_link_info(Path),
            case Type of
                symlink ->
                    {ok, Target} = file:read_link_all(Path),
                    Sha = write_object(Dest, "blob", bin(Target)),
                    {true, {"120000", Name, {Name, Sha}}};
                regular ->
                    {ok, Data} = file:read_file(Path),
                    Sha = write_object(Dest, "blob", Data),
                    FileMode = case Mode band 8#111 of 0 -> "100644"; _ -> "100755" end,
                    {true, {FileMode, Name, {Name, Sha}}};
                directory ->
                    case has_files(Path) of
                        true ->
                            Sha = write_tree(Root, Rel, Gitlinks, Dest),
                            {true, {"40000", <<Name/binary, "/">>, {Name, Sha}}};
                        false ->
                            false
                    end
            end
    end.

%% A file name as the bytes the file system holds.
bin(Name) when is_binary(Name) -> Name;
bin(Name) -> unicode:characters_to_binary(Name, unicode, file:native_name_encoding()).

has_files(Dir) ->
    rp_util:walk(Dir) =/= [].

%% Writes a loose object and returns its raw hash.
write_object(Dest, Type, Data) ->
    Header = [Type, " ", integer_to_list(byte_size(Data)), 0],
    Sha = crypto:hash(sha, [Header, Data]),
    <<Dir:2/binary, File/binary>> = hex(Sha),
    Path = filename:join([Dest, "objects", Dir, File]),
    case filelib:is_regular(Path) of
        true ->
            ok;
        false ->
            rp_util:ensure_dir(filename:dirname(Path)),
            ok = file:write_file(Path, zlib:compress([Header, Data]))
    end,
    Sha.

hex(Raw) -> string:lowercase(binary:encode_hex(Raw)).

hex_to_raw(Hex) -> binary:decode_hex(Hex).

join(<<>>, N) -> N;
join(R, N) -> <<R/binary, "/", N/binary>>.

%% For the lock run: the raw commit object of Rev in the repository at Url,
%% base64-encoded, and the submodule entries of its tree. It fetches the
%% one commit into a scratch repository under Work.
commit_info(Url, Rev) ->
    Work = filename:join(os:getenv("TMPDIR", "/tmp"),
                         "rebar3-purifier-" ++ os:getpid() ++ "-" ++ Rev),
    rp_util:rm_rf(Work),
    rp_util:ensure_dir(Work),
    try
        {0, _} = rp_util:run_quiet("git", ["init", "-q", "--bare", Work], Work, []),
        case rp_util:run_quiet("git", ["-C", Work, "fetch", "-q", "--depth=1", Url, Rev], Work, []) of
            {0, _} -> ok;
            {S, Out} -> rp_util:fail("git fetch ~ts ~ts failed with exit status ~b:~n~ts", [Url, Rev, S, Out])
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
