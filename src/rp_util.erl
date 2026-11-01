%% SPDX-License-Identifier: MIT
%%
%% What the commands share: running programs, the lockfile and its JSON,
%% hashes, and the files that define a build's dependencies.
-module(rp_util).

-include_lib("kernel/include/file.hrl").

-export([
    fail/2,
    run/4,
    run_quiet/4,
    find_executable/1,
    sri_sha256/1,
    hex_md5/1,
    lock_version/0,
    lock_file/1,
    read_lock/1,
    write_json/2,
    definition_files/1,
    definition_hash/2,
    consult/1,
    app_dirs/1,
    ensure_dir/1,
    rm_rf/1,
    walk/1,
    to_bin/1
]).

%% The lock format this command writes and nix/lib reads. nix/lib/
%% lock-version.nix holds the same number.
lock_version() -> 1.

lock_file(Root) -> filename:join(Root, "rebar3-purifier.lock.json").

-spec fail(io:format(), [term()]) -> no_return().
fail(Format, Args) ->
    throw({fail, io_lib:format(Format, Args)}).

%% rebar3 itself. The toolchain's `rebar3` is the interactive wrapper, so
%% the toolchain names the real one in REBAR3_PURIFIER_REBAR3.
find_executable("rebar3") ->
    case os:getenv("REBAR3_PURIFIER_REBAR3") of
        false -> find_on_path("rebar3");
        Path -> Path
    end;
find_executable(Name) ->
    find_on_path(Name).

find_on_path(Name) ->
    case os:find_executable(Name) of
        false -> fail("~ts is not on the PATH", [Name]);
        Path -> Path
    end.

%% Runs Program with Args in Dir, with Env added to the environment, and
%% copies its output to standard error as it comes. Returns the exit
%% status and the output.
run(Program, Args, Dir, Env) -> run(Program, Args, Dir, Env, true).

%% The same, without copying the output.
run_quiet(Program, Args, Dir, Env) -> run(Program, Args, Dir, Env, false).

run(Program, Args, Dir, Env, Echo) ->
    Port = open_port(
        {spawn_executable, find_executable(Program)},
        [
            {args, Args},
            {cd, Dir},
            {env, [{K, V} || {K, V} <- Env]},
            exit_status,
            stderr_to_stdout,
            binary,
            stream
        ]
    ),
    collect(Port, Echo, []).

collect(Port, Echo, Acc) ->
    receive
        {Port, {data, Data}} ->
            Echo andalso io:put_chars(standard_error, Data),
            collect(Port, Echo, [Data | Acc]);
        {Port, {exit_status, Status}} ->
            {Status, iolist_to_binary(lists:reverse(Acc))}
    end.

sri_sha256(Bin) ->
    <<"sha256-", (base64:encode(crypto:hash(sha256, Bin)))/binary>>.

hex_md5(Bin) ->
    string:lowercase(binary:encode_hex(crypto:hash(md5, Bin))).

read_lock(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Lock = json:decode(Bin),
            case maps:get(<<"version">>, Lock, undefined) =:= lock_version() of
                true -> {ok, Lock};
                false -> {error, version}
            end;
        {error, enoent} ->
            {error, enoent}
    end.

%% Writes Term as JSON, with object keys sorted, two-space indentation and
%% a final newline, so a relock that finds the same downloads writes the
%% same bytes.
write_json(File, Term) ->
    ok = file:write_file(File, [encode(Term, 0), $\n]).

encode(Map, _) when is_map(Map), map_size(Map) =:= 0 -> "{}";
encode(Map, Indent) when is_map(Map) ->
    Pad = pad(Indent + 1),
    Keys = lists:sort([to_bin(K) || K <- maps:keys(Map)]),
    Lookup = maps:from_list([{to_bin(K), V} || K := V <- Map]),
    Items = [
        [Pad, json:encode(K), ": ", encode(maps:get(K, Lookup), Indent + 1)]
     || K <- Keys
    ],
    ["{\n", lists:join(",\n", Items), "\n", pad(Indent), "}"];
encode([], _) -> "[]";
encode(List, Indent) when is_list(List) ->
    Pad = pad(Indent + 1),
    Items = [[Pad, encode(V, Indent + 1)] || V <- List],
    ["[\n", lists:join(",\n", Items), "\n", pad(Indent), "]"];
encode(Value, _) ->
    json:encode(Value).

pad(N) -> lists:duplicate(2 * N, $\s).

to_bin(B) when is_binary(B) -> B;
to_bin(A) when is_atom(A) -> atom_to_binary(A);
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(I) when is_integer(I) -> integer_to_binary(I).

%% The files that define the build's dependencies: rebar.config, its
%% script, rebar.lock, and the rebar.config of every application, as paths
%% relative to Root, sorted.
definition_files(Root) ->
    Top = [F || F <- ["rebar.config", "rebar.config.script", "rebar.lock"],
                filelib:is_regular(filename:join(Root, F))],
    Apps = [
        F
     || Dir <- app_dirs(Root),
        Dir =/= ".",
        Name <- ["rebar.config", "rebar.config.script"],
        F <- [filename:join(Dir, Name)],
        filelib:is_regular(filename:join(Root, F))
    ],
    lists:usort(Top ++ Apps).

definition_hash(Root, Files) ->
    Data = [
        [F, 0, element(2, {ok, _} = file:read_file(filename:join(Root, F))), 0]
     || F <- Files
    ],
    sri_sha256(iolist_to_binary(Data)).

consult(File) ->
    case file:consult(File) of
        {ok, Terms} -> Terms;
        {error, enoent} -> [];
        {error, Reason} -> fail("cannot read ~ts: ~p", [File, Reason])
    end.

%% The directories of the project's own applications, relative to Root:
%% "." for an application at the root, and each directory under apps/ or
%% lib/ that holds a src/*.app.src, as rebar3's default lib_dirs find them.
app_dirs(Root) ->
    Root1 = [ "." || filelib:wildcard("src/*.app.src", Root) =/= [] ],
    Nested = lists:usort(
        [filename:dirname(filename:dirname(F))
         || Pattern <- ["apps/*/src/*.app.src", "lib/*/src/*.app.src"],
            F <- filelib:wildcard(Pattern, Root)]
    ),
    Root1 ++ Nested.

ensure_dir(Dir) ->
    ok = filelib:ensure_path(Dir).

rm_rf(Path) ->
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            ok = make_writable(Path),
            {ok, Names} = file:list_dir_all(Path),
            [rm_rf(filename:join(Path, N)) || N <- Names],
            ok = file:del_dir(Path);
        {ok, _} ->
            ok = file:delete(Path);
        {error, enoent} ->
            ok
    end.

make_writable(Dir) ->
    {ok, #file_info{mode = Mode}} = file:read_file_info(Dir),
    file:change_mode(Dir, Mode bor 8#700).

%% Every regular file and symbolic link under Dir, relative to it, sorted.
walk(Dir) ->
    lists:sort(walk(Dir, "")).

walk(Base, Rel) ->
    Path = filename:join(Base, Rel),
    case file:read_link_info(Path) of
        {ok, #file_info{type = directory}} ->
            {ok, Names} = file:list_dir_all(Path),
            lists:append([walk(Base, join(Rel, N)) || N <- Names]);
        {ok, _} ->
            [Rel];
        {error, _} ->
            []
    end.

join("", N) -> N;
join(R, N) -> filename:join(R, N).
