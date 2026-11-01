%% SPDX-License-Identifier: MIT
-module(outdated).

-export([encode/1]).

encode(Term) -> jsx:encode(Term).
