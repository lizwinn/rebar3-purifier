#!/usr/bin/env escript
%% SPDX-License-Identifier: MIT
%%
%% A stand-in for the Hex API, for tests/publish.sh. It listens on a port
%% of its own choosing, writes the port to PORT_FILE, and answers one
%% request: it writes the request line and headers to DIR/request and the
%% body to DIR/body, and replies 201 Created.
%%
%% Usage: fake-hex-api.escript PORT_FILE DIR
main([PortFile, Dir]) ->
    {ok, Listen} = gen_tcp:listen(0, [binary, {active, false}, {packet, http_bin}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, Port} = inet:port(Listen),
    ok = file:write_file(PortFile, integer_to_list(Port)),
    {ok, Socket} = gen_tcp:accept(Listen),
    {ok, {http_request, Method, {abs_path, Path}, _}} = gen_tcp:recv(Socket, 0),
    Headers = headers(Socket, []),
    ok = inet:setopts(Socket, [{packet, raw}]),
    Body = case proplists:get_value(<<"expect">>, Headers) of
        <<"100-continue">> ->
            ok = gen_tcp:send(Socket, <<"HTTP/1.1 100 Continue\r\n\r\n">>),
            body(Socket, Headers);
        _ ->
            body(Socket, Headers)
    end,
    ok = file:write_file(filename:join(Dir, "request"),
                         io_lib:format("~s ~s~n~p~n", [Method, Path, Headers])),
    ok = file:write_file(filename:join(Dir, "body"), Body),
    Reply = term_to_binary(#{<<"url">> => <<"http://127.0.0.1/packages/hello">>}),
    ok = gen_tcp:send(Socket, [
        "HTTP/1.1 201 Created\r\n",
        "content-type: application/vnd.hex+erlang\r\n",
        "content-length: ", integer_to_list(byte_size(Reply)), "\r\n",
        "connection: close\r\n\r\n",
        Reply
    ]),
    gen_tcp:close(Socket).

%% The headers, with lower-case binary names: the packet parser gives
%% well-known names as atoms and others as binaries.
headers(Socket, Acc) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, {http_header, _, Name, _, Value}} ->
            Key = string:lowercase(if is_atom(Name) -> atom_to_binary(Name); true -> Name end),
            headers(Socket, [{Key, Value} | Acc]);
        {ok, http_eoh} ->
            lists:reverse(Acc)
    end.

body(Socket, Headers) ->
    case proplists:get_value(<<"content-length">>, Headers) of
        undefined ->
            <<>>;
        Length ->
            {ok, Body} = gen_tcp:recv(Socket, binary_to_integer(Length)),
            Body
    end.
