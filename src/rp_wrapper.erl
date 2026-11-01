%% SPDX-License-Identifier: MIT
%%
%% Interactive mode. The flake's rebar3 runs `rebar3-purifier env` and
%% evaluates what it prints before it runs the real rebar3. In a build with
%% a current lockfile, that is the environment of the locked downloads:
%% rebar3's cache is a tree of links into the store that holds every locked
%% Hex tarball and the package index of exactly those versions, Hex's
%% default repository points at an address that refuses connections, and
%% git fetches each locked repository from its clone in the store. In any
%% other build it prints nothing, and rebar3 resolves the usual way.
-module(rp_wrapper).

-export([env/0, quote/1]).

env() ->
    {ok, Root} = file:get_cwd(),
    LockFile = rp_util:lock_file(Root),
    case os:getenv("REBAR3_PURIFIER") of
        "0" -> ok;
        _ -> env(Root, LockFile, rp_util:read_lock(LockFile))
    end.

env(_, _, {error, enoent}) ->
    ok;
env(_, LockFile, {error, version}) ->
    warn(
        "~ts was written by another rebar3-purifier version; run `rebar3-purifier relock`. "
        "Resolving the usual way.",
        [LockFile]
    );
env(Root, LockFile, {ok, Lock}) ->
    Files = rp_util:definition_files(Root),
    case maps:get(<<"definitionHash">>, Lock) =:= rp_util:definition_hash(Root, Files) of
        false ->
            warn(
                "the build definition changed since ~ts was written; resolving the usual way "
                "until `rebar3-purifier lock` renews it.",
                [LockFile]
            );
        true ->
            Tree = realize(Root, LockFile),
            Cache = filename:join([Root, "_build", "rebar3-purifier", "cache"]),
            mirror(Tree, Cache),
            print(Tree, Cache, maps:get(<<"gitSources">>, Lock, []))
    end.

warn(Format, Args) ->
    io:format(standard_error, "rebar3-purifier: " ++ Format ++ "~n", Args),
    ok.

%% Builds the cache tree of the lockfile through Nix, with one GC root
%% under _build/rebar3-purifier, and returns its store path.
realize(Root, LockFile) ->
    Link = filename:join([Root, "_build", "rebar3-purifier", "cache-root"]),
    rp_util:ensure_dir(filename:dirname(Link)),
    Args = [
        filename:join(env_var("REBAR3_PURIFIER_NIX_LIB"), "realize.nix"),
        "--arg",
        "lockFile",
        LockFile,
        "--argstr",
        "cli",
        env_var("REBAR3_PURIFIER_CLI"),
        "--arg",
        "nixpkgs",
        env_var("REBAR3_PURIFIER_NIXPKGS"),
        "--argstr",
        "purifierSrc",
        env_var("REBAR3_PURIFIER_PURIFIER_SRC"),
        "--out-link",
        Link
    ],
    case rp_util:run_quiet("nix-build", Args, Root, []) of
        {0, _} ->
            {ok, Tree} = file:read_link_all(Link),
            Tree;
        {Status, Out} ->
            rp_util:fail("building the locked downloads failed with exit status ~b:~n~ts", [
                Status, Out
            ])
    end.

env_var(Name) ->
    case os:getenv(Name) of
        false ->
            rp_util:fail("~ts is not set; run rebar3 through the rebar3-purifier toolchain", [Name]);
        Value ->
            Value
    end.

%% rebar3 writes into its cache, so the cache is a writable tree with the
%% same layout: links to the tarballs, and copies of the index and etags,
%% which rebar3 may rewrite. git fetches from the repositories in the store
%% tree. A marker records the store path the tree mirrors.
mirror(Tree, Cache) ->
    Marker = filename:join(Cache, ".rebar3-purifier-tree"),
    TreeBin = list_to_binary(Tree),
    case file:read_file(Marker) of
        {ok, TreeBin} ->
            ok;
        _ ->
            rp_util:rm_rf(Cache),
            rp_util:ensure_dir(Cache),
            HexTree = filename:join(Tree, "hex"),
            lists:foreach(
                fun(Rel) ->
                    From = filename:join(HexTree, Rel),
                    To = filename:join([Cache, "hex", Rel]),
                    rp_util:ensure_dir(filename:dirname(To)),
                    case filename:extension(Rel) of
                        ".tar" ->
                            {ok, Target} = file:read_link_all(From),
                            ok = file:make_symlink(Target, To);
                        _ ->
                            {ok, _} = file:copy(From, To),
                            ok = file:change_mode(To, 8#644)
                    end
                end,
                rp_util:walk(HexTree)
            ),
            ok = file:write_file(Marker, Tree)
    end.

print(Tree, Cache, GitSources) ->
    Count =
        case os:getenv("GIT_CONFIG_COUNT") of
            false -> 0;
            N -> list_to_integer(N)
        end,
    GitConfig =
        [{"safe.directory", "*"}] ++
            [
                {
                    "url." ++ filename:join(Tree, binary_to_list(P)) ++ ".insteadOf",
                    binary_to_list(U)
                }
             || #{<<"url">> := U, <<"path">> := P} <- GitSources
            ],
    Lines =
        [
            export("REBAR_CACHE_DIR", Cache),
            %% Port 9 (discard) refuses connections, so Hex's default
            %% repository fails at once and rebar3 takes the cached tarball.
            export("HEX_CDN", "http://127.0.0.1:9"),
            export("GIT_CONFIG_COUNT", integer_to_list(Count + length(GitConfig)))
        ] ++
            lists:append([
                [
                    export("GIT_CONFIG_KEY_" ++ integer_to_list(Count + I - 1), K),
                    export("GIT_CONFIG_VALUE_" ++ integer_to_list(Count + I - 1), V)
                ]
             || {I, {K, V}} <- lists:enumerate(GitConfig)
            ]),
    io:put_chars(Lines),
    ok.

export(Name, Value) ->
    ["export ", Name, "=", quote(Value), "\n"].

%% A shell word that stands for Value.
quote(Value) ->
    [$', string:replace(Value, "'", "'\\''", all), $'].
