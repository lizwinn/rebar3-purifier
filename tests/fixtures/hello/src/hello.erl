-module(hello).

-export([main/1, greeting/1, name/0]).

%% The escript prints the greeting for its argument.
main([Name]) ->
    io:format("~s~n", [greeting(list_to_binary(Name))]);
main([]) ->
    io:format("~s~n", [greeting(name())]).

%% A JSON object that greets Name.
greeting(Name) ->
    jsx:encode(#{<<"hello">> => Name}).

name() ->
    <<"world">>.
