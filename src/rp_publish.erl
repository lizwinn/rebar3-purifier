%% SPDX-License-Identifier: MIT
%%
%% `rebar3-purifier publish`: builds the `release` of buildRebar3Project,
%% the Hex package tarballs of the project, through Nix from the project
%% directory, and uploads those tarballs to the Hex API with rebar3's own
%% Hex client. Nothing is built outside the sandbox.
%%
%% HEX_API_KEY holds the key to publish with. HEX_API_URL replaces the
%% default API (https://hex.pm/api), and HEX_ORGANIZATION publishes into an
%% organization. `--dry-run` builds and prints the tarballs without
%% uploading them. Named applications limit the upload to their packages.
-module(rp_publish).

-export([publish/1]).

publish(Args) ->
    {Project, Rest} = rp_util:project(Args),
    DryRun = lists:member("--dry-run", Rest),
    Selected = Rest -- ["--dry-run"],
    Lock = rp_check:current(Project),
    Packages = [
        {maps:get(<<"name">>, P), maps:get(<<"version">>, P)}
     || P <- maps:get(<<"hexPackages">>, maps:get(<<"outputs">>, Lock))
    ],
    Packages =/= [] orelse
        rp_util:fail(
            "the lockfile lists no Hex packages; add rebar3_hex to project_plugins and run "
            "`rebar3-purifier lock`",
            []
        ),
    Names =
        case Selected of
            [] -> [N || {N, _} <- Packages];
            _ -> [list_to_binary(S) || S <- Selected]
        end,
    [
        lists:keymember(N, 1, Packages) orelse
            rp_util:fail("~ts is not a Hex package of this build", [N])
     || N <- Names
    ],
    Release = build(Project),
    Tarballs = [
        filename:join(Release, <<N/binary, "-", V/binary, ".tar">>)
     || {N, V} <- Packages, lists:member(N, Names)
    ],
    case DryRun of
        true -> [io:format("~ts~n", [T]) || T <- Tarballs];
        false -> [upload(T) || T <- Tarballs]
    end,
    ok.

%% The `release` of buildRebar3Project, built from the project directory,
%% with a GC root under _build/rebar3-purifier.
build(#{
    root := Root,
    lock_file := LockFile,
    rebar_lock := RebarLock,
    tree_rebar_lock := InTree
}) ->
    Link = filename:join([Root, "_build", "rebar3-purifier", "publish"]),
    rp_util:ensure_dir(filename:dirname(Link)),
    RebarLockArg =
        case RebarLock =:= InTree of
            true -> "";
            false -> ["rebarLock = ", nix_path(RebarLock), "; "]
        end,
    Expr = iolist_to_binary([
        "let pkgs = import ",
        nix_string(env("REBAR3_PURIFIER_NIXPKGS")),
        " { }; ",
        "purifier = import (builtins.storePath ",
        nix_string(env("REBAR3_PURIFIER_PURIFIER_SRC")),
        " + \"/nix/lib\") { inherit (pkgs) lib; }; ",
        "build = pkgs.callPackage ",
        nix_string(filename:join(env("REBAR3_PURIFIER_NIX_LIB"), "build-rebar3-project.nix")),
        " { inherit purifier; cli = builtins.storePath ",
        nix_string(cli_package()),
        "; }; ",
        "in (build { src = builtins.path { path = ",
        nix_path(Root),
        "; name = \"source\"; ",
        "filter = p: t: !builtins.elem (baseNameOf p) [ \"_build\" \".git\" \".rebar3-purifier-gcroots\" ]; }; ",
        "lockFile = ",
        nix_path(LockFile),
        "; ",
        RebarLockArg,
        "}).release"
    ]),
    case rp_util:run("nix-build", ["-E", binary_to_list(Expr), "--out-link", Link], Root, []) of
        {0, _} ->
            {ok, Release} = file:read_link_all(Link),
            Release;
        {Status, _} ->
            rp_util:fail("building the Hex packages failed with exit status ~b", [Status])
    end.

%% An absolute path as a Nix path.
nix_path(Path) -> ["(/. + ", nix_string(Path), ")"].

%% The store path of the rebar3-purifier package, from the path of its
%% command.
cli_package() ->
    filename:dirname(filename:dirname(env("REBAR3_PURIFIER_CLI"))).

env(Name) ->
    case os:getenv(Name) of
        false -> rp_util:fail("~ts is not set; run rebar3-purifier from its toolchain", [Name]);
        Value -> Value
    end.

nix_string(S) ->
    Escaped = lists:flatmap(
        fun
            ($") -> "\\\"";
            ($\\) -> "\\\\";
            ($$) -> "\\$";
            (C) -> [C]
        end,
        unicode:characters_to_list(S)
    ),
    [$", Escaped, $"].

upload(Tarball) ->
    Key =
        case os:getenv("HEX_API_KEY") of
            false -> rp_util:fail("HEX_API_KEY is not set", []);
            K -> list_to_binary(K)
        end,
    {ok, _} = application:ensure_all_started([inets, ssl]),
    Base = r3_hex_core:default_config(),
    Config = Base#{
        api_key => Key,
        api_url =>
            case os:getenv("HEX_API_URL") of
                false -> maps:get(api_url, Base);
                Url -> list_to_binary(Url)
            end,
        api_organization =>
            case os:getenv("HEX_ORGANIZATION") of
                false -> undefined;
                Org -> list_to_binary(Org)
            end
    },
    {ok, Bin} = file:read_file(Tarball),
    case r3_hex_api_release:publish(Config, Bin) of
        {ok, {Status, _, _}} when Status >= 200, Status < 300 ->
            io:format("published ~ts~n", [filename:basename(Tarball)]);
        {ok, {Status, _, Body}} ->
            rp_util:fail("Hex refused ~ts with HTTP ~b: ~p", [
                filename:basename(Tarball), Status, Body
            ]);
        {error, Reason} ->
            rp_util:fail("publishing ~ts failed: ~p", [filename:basename(Tarball), Reason])
    end.
