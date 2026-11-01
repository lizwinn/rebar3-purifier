-module(hello_app).

-behaviour(application).

-export([start/2, stop/1]).

%% With HELLO_ONESHOT set, the release prints a greeting and stops, so a
%% check can run it in the foreground.
start(_Type, _Args) ->
    case os:getenv("HELLO_ONESHOT") of
        false ->
            ok;
        _ ->
            io:format("~s~n", [hello:greeting(<<"release">>)]),
            spawn(fun() -> init:stop() end)
    end,
    {ok, spawn(fun() -> receive stop -> ok end end)}.

stop(_State) ->
    ok.
