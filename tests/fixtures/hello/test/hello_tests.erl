-module(hello_tests).

-include_lib("eunit/include/eunit.hrl").

greeting_test() ->
    ?assertEqual(<<"{\"hello\":\"Nix\"}">>, hello:greeting(<<"Nix">>)).

%% meck, the git dependency of the test profile, replaces name/0.
mocked_name_test() ->
    meck:new(hello, [passthrough]),
    meck:expect(hello, name, fun() -> <<"meck">> end),
    ?assertEqual(<<"meck">>, hello:name()),
    meck:unload(hello).
