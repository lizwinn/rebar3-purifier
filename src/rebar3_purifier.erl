%% SPDX-License-Identifier: MIT
%%
%% The rebar3-purifier command. It runs on the Erlang of the package set,
%% with the modules of the rebar3 escript on its code path, so it reads
%% Hex tarballs and builds the package index with rebar3's own code.
-module(rebar3_purifier).

-export([main/1]).

usage() ->
    "usage: rebar3-purifier <command> [arguments]\n"
    "\n"
    "  lock [--profile P]...   lock the build in the current directory, when\n"
    "                          a file that defines its dependencies changed\n"
    "  relock [--profile P]... lock it regardless\n"
    "  env                     print the environment that points rebar3 at\n"
    "                          the locked downloads (used by the rebar3\n"
    "                          wrapper)\n"
    "  publish [APP]...        publish the Hex packages Nix built\n"
    "  build-cache             the builder of the cache tree (in Nix)\n"
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

run(["lock" | Rest]) -> rp_lock:lock(Rest, false);
run(["relock" | Rest]) -> rp_lock:lock(Rest, true);
run(["env"]) -> rp_wrapper:env();
run(["publish" | Rest]) -> rp_publish:publish(Rest);
run(["build-cache"]) -> rp_index:build_cache();
run(["index", Dir]) -> rp_index:index(Dir);
run(["help"]) -> io:put_chars(usage()), ok;
run(_) ->
    io:put_chars(standard_error, usage()),
    {exit, 2}.
