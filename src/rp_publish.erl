%% SPDX-License-Identifier: MIT
%%
%% `rebar3-purifier publish`: builds the Hex packages of the lockfile's
%% outputs through Nix, from the project directory, and uploads those
%% tarballs to the Hex API with rebar3's own Hex client. Nothing is built
%% outside the sandbox.
%%
%% HEX_API_KEY holds the key to publish with. HEX_API_URL replaces the
%% default API (https://hex.pm/api), and HEX_ORGANIZATION publishes into an
%% organization. `--dry-run` builds and prints the tarballs without
%% uploading them.
-module(rp_publish).

-export([publish/1]).

publish(Args) ->
    DryRun = lists:member("--dry-run", Args),
    Selected = Args -- ["--dry-run"],
    {ok, Root} = file:get_cwd(),
    LockFile = rp_util:lock_file(Root),
    Lock =
        case rp_util:read_lock(LockFile) of
            {ok, L} ->
                L;
            {error, _} ->
                rp_util:fail("~ts is missing or from another version; run `rebar3-purifier lock`", [
                    LockFile
                ])
        end,
    maps:get(<<"definitionHash">>, Lock) =:=
        rp_util:definition_hash(Root, rp_util:definition_files(Root)) orelse
        rp_util:fail("~ts is out of date; run `rebar3-purifier lock` and commit it first", [
            LockFile
        ]),
    Packages = [
        maps:get(<<"name">>, P)
     || P <- maps:get(<<"hexPackages">>, maps:get(<<"outputs">>, Lock))
    ],
    Packages =/= [] orelse
        rp_util:fail(
            "the lockfile lists no Hex packages; add rebar3_hex to project_plugins and relock", []
        ),
    Names =
        case Selected of
            [] -> Packages;
            _ -> [list_to_binary(S) || S <- Selected]
        end,
    [
        lists:member(N, Packages) orelse rp_util:fail("~ts is not a Hex package of this build", [N])
     || N <- Names
    ],
    Tarballs = [build(Root, N) || N <- Names],
    case DryRun of
        true -> [io:format("~ts~n", [T]) || T <- Tarballs];
        false -> [upload(T) || T <- Tarballs]
    end,
    ok.

%% The tarball of package Name, built by buildRebar3Project from the
%% project directory, with a GC root under _build/rebar3-purifier.
build(Root, Name) ->
    Link = filename:join([Root, "_build", "rebar3-purifier", "publish", binary_to_list(Name)]),
    rp_util:ensure_dir(filename:dirname(Link)),
    Expr = iolist_to_binary([
        "let pkgs = import ",
        nix_string(env("REBAR3_PURIFIER_NIXPKGS")),
        " { }; ",
        "build = pkgs.callPackage ",
        nix_string(filename:join(env("REBAR3_PURIFIER_NIX_LIB"), "build-rebar3-project.nix")),
        " { rebar3-purifier.cli = builtins.storePath ",
        nix_string(cli_package()),
        "; purifier = import (builtins.storePath ",
        nix_string(env("REBAR3_PURIFIER_PURIFIER_SRC")),
        " + \"/nix/lib\") { inherit (pkgs) lib; }; }; ",
        "in (build { src = builtins.path { path = ",
        nix_string(Root),
        "; name = \"source\"; ",
        "filter = p: t: baseNameOf p != \"_build\" && baseNameOf p != \".git\"; }; }).hexPackages.",
        nix_attr(Name)
    ]),
    case rp_util:run("nix-build", ["-E", binary_to_list(Expr), "--out-link", Link], Root, []) of
        {0, _} ->
            [Tarball] = filelib:wildcard(filename:join(Link, "*.tar")),
            Tarball;
        {Status, _} ->
            rp_util:fail("building the Hex package ~ts failed with exit status ~b", [Name, Status])
    end.

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

nix_attr(Name) -> nix_string(Name).

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
