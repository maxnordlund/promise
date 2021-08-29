-include_lib("stdlib/include/assert.hrl").

-define(is_exception(Class),
    Class =:= throw orelse Class =:= error orelse Class =:= exit
).

-define(is_timeout(Timeout),
    Timeout =:= infinity orelse
        (is_integer(Timeout) andalso Timeout >= 0)
).

-define(ensurePromise(Promise, Arguments),
    case promise:is_promise(Promise) of
        true ->
            ok;
        false ->
            erlang:error(badarg, Arguments, [
                {error_info, #{
                    cause => not_promise
                }}
            ]);
        unknown ->
            erlang:error(badarg, Arguments, [
                {error_info, #{
                    cause => dead_process
                }}
            ])
    end
).

-define(ensurePromise(Promise, Arguments, Message),
    case promise:is_promise(Promise) of
        true ->
            ok;
        false ->
            erlang:error(badarg, Arguments, [
                {error_info, #{
                    cause => not_promise,
                    message => Message
                }}
            ]);
        unknown ->
            erlang:error(badarg, Arguments, [
                {error_info, #{
                    cause => dead_process,
                    message => Message
                }}
            ])
    end
).

-type class() :: throw | error | exit.
-type stacktrace() :: [
    {
        Module :: module(),
        Function :: atom(),
        Arity :: arity() | (Args :: [term()]),
        Location :: [
            {file, Filename :: string()}
            | {line, Line :: pos_integer()}
            | {error_info, #{
                module => module(), %% Defaults to `Module'
                function => atom(), %% Defaults to `format_error'
                cause => term()
            }}
        ]
    }
].
