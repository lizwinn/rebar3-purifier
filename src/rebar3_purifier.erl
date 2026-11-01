%% SPDX-License-Identifier: MIT
%%
%% The rebar3-purifier command. It runs on the Erlang of the package set,
%% with the modules of the rebar3 escript on its code path, so it reads
%% Hex tarballs and builds the package index with rebar3's own code.
-module(rebar3_purifier).

-export([main/1]).

usage() ->
    "usage: rebar3-purifier <command> [--lockfile PATH] [arguments]\n"
    "\n"
    "  lock [--profile P]...   run rebar3 with empty caches and record its downloads\n"
    "                          in rebar3-purifier.lock.json, keeping rebar.lock\n"
    "  update [--profile P]... [PACKAGE]...\n"
    "                          upgrade every dependency in rebar.lock, or the\n"
    "                          named ones, then lock\n"
    "  prefetch                fetch the locked downloads and keep them and the\n"
    "                          toolchain alive, for work without the network\n"
    "  publish [--dry-run] [APP]...\n"
    "                          publish the Hex packages Nix built\n"
    "\n"
    "  --lockfile PATH names a lockfile outside the project.\n"
    "\n"
    "Used by the toolchain and the Nix build:\n"
    "  env                     print the environment that points rebar3 at the\n"
    "                          locked downloads\n"
    "  build-cache             build the cache tree\n"
    "  check DIR LOCKFILE      check that the lockfile fits the build in DIR\n"
    "  pin-versions DIR LOCKFILE\n"
    "                          write the versions the lock run recorded into\n"
    "                          applications whose version comes from git\n"
    "  index DIR               write the package index and etags of the Hex\n"
    "                          tarballs under DIR/hex\n".

main(Args) ->
    Code =
        try run(Args) of
            ok -> 0;
            {exit, C} -> C
        catch
            throw:{fail, Message} ->
                io:format(standard_error, "rebar3-purifier: ~ts~n", [Message]),
                1
        end,
    erlang:halt(Code).

run(["lock" | Rest]) ->
    rp_lock:lock(Rest);
run(["update" | Rest]) ->
    rp_lock:update(Rest);
run(["prefetch" | Rest]) ->
    rp_wrapper:prefetch(Rest);
run(["publish" | Rest]) ->
    rp_publish:publish(Rest);
run(["env"]) ->
    rp_wrapper:env();
run(["build-cache"]) ->
    rp_index:build_cache();
run(["index", Dir]) ->
    rp_index:index(Dir);
run(["check", Dir, LockFile]) ->
    rp_check:check(Dir, LockFile);
run(["pin-versions", Dir, LockFile]) ->
    rp_versions:pin(Dir, LockFile);
run(["help"]) ->
    io:put_chars(usage()),
    ok;
run(_) ->
    io:put_chars(standard_error, usage()),
    {exit, 2}.
