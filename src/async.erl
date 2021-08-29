-module(async).

%% Creating new promises
-export([
    apply/1,
    apply/2,
    apply/3
]).

%% Retriving the result of the promise
-export([
    await/1,
    await/2,
    settle/1,
    settle/2
]).

%% Transformations
-export([
    all/1,
    do/2,
    filter/2,
    map/2,
    map/3,
    race/1,
    race/2,
    then/2,
    then/3,
    then/4
]).

%% Only exported to make {@link erlang:spawn_link/3} happy
-export([
    call/3
]).

%% Erlang specific
-export([
    format_error/2
]).

-compile({no_auto_import, [apply/2]}).

-include("internal.hrl").

-type options() :: #{
    timeout => timeout(),
    concurrency => non_neg_integer()
}.

-spec apply(fun(() -> Term)) -> promise:t(Term).
apply(Fun) when is_function(Fun, 0) ->
    apply(Fun, []).

-spec apply(fun((...) -> Term), [term()]) -> promise:t(Term).
apply(Fun, Arguments) when is_function(Fun, length(Arguments)) ->
    case maps:from_list(erlang:fun_info(Fun)) of
        #{type := local} ->
            ok;
        #{module := Module, name := Function, arity := Arity} ->
            case erlang:function_exported(Module, Function, Arity) of
                true ->
                    ok;
                false ->
                    Location =
                        case code:which(Module) of
                            Beamfile when is_list(Beamfile) ->
                                case filelib:find_source(Beamfile) of
                                    {ok, Source} ->
                                        [{file, Source}];
                                    _ ->
                                        []
                                end;
                            _ ->
                                []
                        end,
                    erlang:raise(error, undef, [
                        {Module, Function, Arguments, Location}
                    ])
            end
    end,
    spawn_link(?MODULE, call, [self(), Fun, Arguments]);
apply(Fun, Arguments) when is_function(Fun) ->
    error({badarity, {Fun, Arguments}}).

-spec apply(module(), atom(), [term()]) -> promise:t(term()).
apply(Module, Function, Arguments) when
    is_atom(Module) andalso is_atom(Function) andalso is_list(Arguments)
->
    Arity = length(Arguments),
    apply(fun Module:Function/Arity, Arguments).

%% @private
call(From, Fun, Arguments) when
    is_pid(From) andalso is_function(Fun, length(Arguments))
->
    %% Mark this process to allow `promise:is_promise/1' to work
    put('$promise', pending),
    put('$parent', From),
    Result =
        try erlang:apply(Fun, Arguments) of
            Promise when is_pid(Promise) ->
                case promise:is_promise(Promise) of
                    true ->
                        settle(Promise);
                    false ->
                        badpromise(not_promise, From, Fun, Arguments);
                    unknown ->
                        badpromise(dead_process, From, Fun, Arguments)
                end;
            Value ->
                {value, Value}
        catch
            Class:Reason:Stacktrace ->
                {Class, Reason, Stacktrace}
        end,
    promise:start_loop(Result).

%% @private
badpromise(Cause, From, Fun, Arguments) ->
    {error, badarg, [
        {?MODULE, call, [From, Fun, Arguments], [{error_info, #{cause => Cause}}]}
    ]}.

-spec await(PromiseOrPromises) -> Term when
    PromiseOrPromises :: promise:t(Term) | [promise:t(Term)].
await(PromiseOrPromises) when
    is_pid(PromiseOrPromises) orelse is_list(PromiseOrPromises)
->
    await(PromiseOrPromises, #{}).

-spec await(PromiseOrPromises, options()) -> Term when
    PromiseOrPromises :: promise:t(Term) | [promise:t(Term)].
await(Promises, Options) when is_list(Promises) ->
    [await(Promise, Options) || Promise <- Promises];
await(Promise, Options) when is_pid(Promise) andalso is_map(Options) ->
    unwrap(settle(Promise, Options)).

-spec settle(promise:t(Term)) -> Result when
    Result :: {value, Term} | {class(), Reason, stacktrace()},
    Reason :: term().
settle(Promise) when is_pid(Promise) ->
    settle(Promise, #{}).

-spec settle(promise:t(Term), options()) -> Result when
    Result :: {value, Term} | {class(), Reason, stacktrace()} | pending,
    Reason :: term().
settle(Promise, Options) when is_pid(Promise) andalso is_map(Options) ->
    send_await(Promise),
    receive_fulfilled(Options).

then(Promise, Success) when is_function(Success, 1) ->
    then(Promise, Success, #{}).

then(Promise, Success, Options) when is_function(Success, 1) andalso is_map(Options) ->
    apply(fun() -> Success(await(Promise, Options)) end);
then(Promise, Success, Failure) when
    is_pid(Promise) andalso is_function(Success, 1) andalso
        (is_function(Failure, 2) orelse is_function(Failure, 3))
->
    then(Promise, Success, Failure, #{}).

then(Promise, Success, Failure, Options) when
    is_function(Success, 1) andalso
        (is_function(Failure, 2) orelse is_function(Failure, 3)) andalso
        is_map(Options)
->
    apply(fun then_internal/4, [Promise, Success, Failure, Options]).

%% @private
then_internal(Promise, Success, Failure, Options) when
    is_pid(Promise) andalso is_function(Success, 1) andalso
        (is_function(Failure, 2) orelse is_function(Failure, 3)) andalso
        is_map(Options)
->
    then_internal(settle(Promise, Options), Success, Failure).

%% @private
then_internal({value, Value}, Success, Failure) when
    is_function(Success, 1) andalso
        (is_function(Failure, 2) orelse is_function(Failure, 3))
->
    Success(Value);
then_internal({Class, Reason, _Stacktrace}, Success, Failure) when
    is_function(Success, 1) andalso is_function(Failure, 2)
->
    Failure(Class, Reason);
then_internal({Class, Reason, Stacktrace}, Success, Failure) when
    is_function(Success, 1) andalso is_function(Failure, 3)
->
    Failure(Class, Reason, Stacktrace).

%% @doc Returns a promise with the given function applied to the given list of
%% promises, or values.
%%
%% It's a more efficient version of:
%%
%% ```
%% promise:resolve(
%%     lists:map(Fun, async:await(lists:map(promise:resolve/1, PromisesOrTerms)))
%% )
%% '''
-spec map(PromisesOrTerms, fun((A) -> B)) -> promise:t([B]) when
    PromisesOrTerms :: A | promise:t(A).
map(PromisesOrTerms, Fun) when is_list(PromisesOrTerms) andalso is_function(Fun, 1) ->
    map(PromisesOrTerms, Fun, #{}).

-spec map(PromisesOrTerms, fun((A) -> B), options()) -> promise:t([B]) when
    PromisesOrTerms :: A | promise:t(A).
map(PromisesOrTerms, Fun, #{concurrency := Concurrency}) when
    is_list(PromisesOrTerms) andalso is_function(Fun, 1) andalso is_integer(Concurrency) andalso
        Concurrency > 0
->
    apply(fun map_internal/5, [PromisesOrTerms, Fun, [], [], Concurrency]);
map(PromisesOrTerms, Fun, Options) when
    is_list(PromisesOrTerms) andalso is_function(Fun, 1) andalso is_map(Options)
->
    apply(fun map_internal/2, [PromisesOrTerms, Fun]).

map_internal(PromisesOrTerms, Fun) ->
    [then(promise:resolve(MaybePromise), Fun) || MaybePromise <- PromisesOrTerms].

map_internal([], _Fun, ResultPromises, Results, _) ->
    lists:reverse(await(ResultPromises), Results);
map_internal(PromisesOrTerms, Fun, [ResultPromise | ResultPromises], Results, 0) ->
    %% Can't run anymore in parallel, so first we must wait for one of the
    %% currently running tasks to finish.
    Result =
        case promise:is_promise(ResultPromise) of
            true -> await(ResultPromise);
            false -> ResultPromise
        end,
    map_internal(PromisesOrTerms, Fun, ResultPromises, [Result | Results], 1);
map_internal([MaybePromise | PromisesOrTerms], Fun, ResultPromises, Results, 1) ->
    %% We want to run as much as possible in parallel, but here we're left
    %% with the final concurrent task. So we can afford to (maybe) run it in
    %% this process; saving a bit on memory.
    ResultPromise =
        case promise:is_promise(MaybePromise) of
            true -> then(MaybePromise, Fun);
            false -> Fun(MaybePromise)
        end,
    map_internal(PromisesOrTerms, Fun, [ResultPromise | ResultPromises], Results, 0);
map_internal(
    [MaybePromise | PromisesOrTerms], Fun, ResultPromises, Results, Concurrency
) ->
    %% Until we hit the concurrency cap we always run the function in a
    %% separate process.
    map_internal(
        PromisesOrTerms,
        Fun,
        [then(promise:resolve(MaybePromise), Fun) | ResultPromises],
        Results,
        Concurrency - 1
    ).

%% @doc Returns a promise with the given list of promises, or values, filtered
%% by the given function.
%%
%% It's a more efficient version of:
%%
%% ```
%% promise:resolve(
%%     lists:filter(Fun, async:await(lists:map(promise:resolve/1, PromisesOrTerms)))
%% )
%% '''
filter(PromisesOrTerms, Fun) when
    is_list(PromisesOrTerms) andalso is_function(Fun, 1)
->
    filter(PromisesOrTerms, Fun, #{}).

filter(PromisesOrTerms, Fun, Options) when
    is_list(PromisesOrTerms) andalso is_function(Fun, 1) andalso is_map(Options)
->
    %% We do it this way to maximise concurrency, while at the same time only
    %% await each promise once.
    apply(fun() ->
        lists:filtermap(
            fun filter_filtermapper/1,
            await(
                map(
                    PromisesOrTerms,
                    fun(Term) ->
                        {Fun(Term), Term}
                    end,
                    Options
                )
            )
        )
    end).

%% @private
filter_filtermapper({false, _}) -> false;
filter_filtermapper({true, _} = Result) -> Result.

do(PromiseOrTerm, []) ->
    promise:resolve(PromiseOrTerm);
do(PromiseOrTerm, Functions) when is_function(hd(Functions), 1) ->
    lists:foldl(
        fun
            (Fun, Promise) when is_function(Fun, 1) ->
                then(Promise, Fun);
            ({Fun, ExtraArguments}, Promise) when
                is_function(Fun, 1 + length(ExtraArguments))
            ->
                %% Could also be written as
                %% then(all([Fun, all([|Value | ExtraArguments])]), fun erlang:apply/2)
                %% But that's just unreadable
                then(Promise, fun(Value) ->
                    erlang:apply(Fun, [Value | ExtraArguments])
                end)
        end,
        promise:resolve(PromiseOrTerm),
        Functions
    ).

%% @doc Returns a promise with all promises successfully resolved, or fails
%% with the exception from the first failed promise in the given list of
%% promises.
%%
%% You may also give a list of mixed promises and values, in which case only
%% promises are {@link await/1. awaited} for.
all(PromisesOrTerms) ->
    apply(fun all_internal/1, [PromisesOrTerms]).

%% @private
all_internal(PromisesOrTerms) ->
    [
        case promise:is_promise(MaybePromise) of
            true -> await(MaybePromise);
            false -> MaybePromise
        end
     || MaybePromise <- PromisesOrTerms
    ].

-spec race([promise:t(Term)]) -> promise:t(Term).
race(Promises) when is_list(Promises) ->
    race(Promises, #{}).

-spec race([promise:t(Term)], options()) -> promise:t(Term).
race([], _) ->
    error(badarg);
race(Promises, Options) when is_list(Promises) andalso is_map(Options) ->
    apply(fun race_internal/2, [Promises, Options]).

%% @private
%% @doc Scatter/gathers the first successful result, or fails with all
%% failures, for the given list of promises.
race_internal(Promises, Options) ->
    lists:foreach(fun send_await/1, Promises),
    unwrap(receive_first_success_or_all_failures(Options, length(Promises), [])).

%% @private
receive_first_success_or_all_failures(Options, 1, Exceptions) ->
    case receive_fulfilled(Options) of
        {value, _} = Result ->
            Result;
        Exception ->
            {error, lists:reverse(Exceptions, [Exception]), []}
    end;
receive_first_success_or_all_failures(Options, TriesLeft, Exceptions) ->
    case receive_fulfilled(Options) of
        {value, _} = Result ->
            Result;
        Exception ->
            receive_first_success_or_all_failures(Options, TriesLeft - 1, [
                Exception | Exceptions
            ])
    end.

format_error(badarg, [{?MODULE, call, [_From, _Fun, _Arguments], Info} | _]) ->
    ErrorInfoMap = proplists:get_value(error_info, Info, #{}),
    ErrorMap = format_argument_error_message(ErrorInfoMap),
    ErrorMap#{
        general =>
            "Any pid returned from within a promise handler must refer to another promise."
    };
format_error(_, _) ->
    #{}.

format_argument_error_message(#{module := ?MODULE, cause := not_promise}) ->
    #{2 => <<"returned a pid that is not a promise">>};
format_argument_error_message(#{module := ?MODULE, cause := dead_process}) ->
    #{2 => <<"returned a pid to a dead process">>};
format_argument_error_message(_) ->
    #{}.

%% @private
send_await(Promise) when is_pid(Promise) ->
    Promise ! {await, self()}.

%% @private
receive_fulfilled(#{timeout := Timeout}) when ?is_timeout(Timeout) ->
    receive
        {fulfilled, Result} -> Result
    after Timeout ->
        pending
    end;
receive_fulfilled(Options) when is_map(Options) ->
    receive
        {fulfilled, Result} -> Result
    end.

%% @private
unwrap({value, Value}) ->
    Value;
unwrap({Class, Reason, Stacktrace}) when ?is_exception(Class) ->
    erlang:raise(Class, Reason, Stacktrace);
unwrap(pending) ->
    error(pending).
