-module(promise).

%% Introspection
-export([
    is_promise/1
]).

%% Creating new promises
-export([
    resolve/1,
    reject/1,
    reject/2,
    reject/3
]).

%% Erlang specific
-export([
    format_error/2,
    stop/1,
    stop/2
]).

%% Internals
-export([
    %% Exported to make {@link erlang:spawn_link/3} happy
    start_loop/1
]).

-export_type([
    t/1
]).

-type t(_Term) :: pid().

-include("internal.hrl").

-define(HIBERNATE_AFTER, 5000).

-spec resolve(Term | t(Term)) -> t(Term).
resolve(PromiseOrTerm) ->
    Value =
        case is_promise(PromiseOrTerm) of
            true -> async:await(PromiseOrTerm);
            false -> PromiseOrTerm
        end,
    spawn_link(?MODULE, start_loop, [{value, Value}]).

-spec reject(Reason | t(Reason)) -> t(no_return()) when
    Reason :: term().
reject(Reason) ->
    case is_promise(Reason) of
        true ->
            case async:settle(Reason) of
                {value, RealReason} ->
                    reject(throw, RealReason);
                {Class, RealReason, Stacktrace} ->
                    reject(Class, RealReason, Stacktrace)
            end;
        false ->
            reject(throw, Reason)
    end.

-spec reject(class(), term()) -> t(no_return()).
reject(Class, Reason) when ?is_exception(Class) ->
    {current_stacktrace, Stacktrace} = process_info(self(), current_stacktrace),
    reject(Class, Reason, Stacktrace).

-spec reject(class(), term(), stacktrace()) -> t(no_return()).
reject(Class, Reason, Stacktrace) when ?is_exception(Class) ->
    spawn_link(?MODULE, start_loop, [{Class, Reason, Stacktrace}]).

%% @doc Returns true iff the given term is a pid for a promise, false if it is
%% certain the given term is not a promise, or unknown if it can't determine
%% this.
%%
%% The latter happens if the given term is a pid for a dead process, or if it
%% dies during testing.
%%
%% This tries to minimize the amount of data inspected, which is why the
%% process can die during the test.
-spec is_promise(term()) -> boolean() | unknown.
is_promise(MaybePromise) when is_pid(MaybePromise) ->
    case is_process_alive(MaybePromise) of
        true ->
            case process_info(MaybePromise, current_function) of
                undefined ->
                    unknown;
                {current_function, {?MODULE, start_loop, 1}} ->
                    true;
                {current_function, {?MODULE, loop, 1}} ->
                    true;
                _ ->
                    case process_info(MaybePromise, dictionary) of
                        undefined ->
                            unknown;
                        {dictionary, ProcessDictionary} ->
                            proplists:is_defined('$promise', ProcessDictionary)
                    end
            end;
        false ->
            unknown
    end;
is_promise(_) ->
    false.

-spec stop(PromiseOrPromises) -> ok when
    PromiseOrPromises :: t(any()) | [t(any())].
stop(PromisesOrTerms) when is_list(PromisesOrTerms) ->
    Promises = lists:filter(fun is_pid/1, PromisesOrTerms),
    %% First send the exit signal to all promises,
    lists:foreach(
        fun(Promise) ->
            ?ensurePromise(Promise, [Promise]),
            exit(Promise, normal)
        end,
        Promises
    ),
    %% then make sure they are dead.
    lists:foreach(fun stop/1, Promises);
stop(Promise) when is_pid(Promise) ->
    exit(Promise, normal),
    case is_process_alive(Promise) of
        false ->
            ok;
        true ->
            unlink(Promise),
            exit(Promise, kill),
            %% This makes sure the process has been killed before returning
            is_process_alive(Promise),
            ok
    end.

-spec stop(PromiseOrPromises, Timeout) -> ok when
    PromiseOrPromises :: t(any()) | [t(any())],
    Timeout :: non_neg_integer().
stop(Promises, Timeout) when is_list(Promises) andalso ?is_timeout(Timeout) ->
    %% First send the exit signal to all promises,
    lists:foreach(fun(Promise) -> exit(Promise, normal) end, Promises),
    %% then make sure they are dead.
    lists:foreach(fun(Promise) -> stop(Promise, Timeout) end, Promises);
stop(Promise, infinity) when is_pid(Promise) ->
    error({badarg, "must use finite timeout"});
stop(Promise, Timeout) when is_pid(Promise) andalso ?is_timeout(Timeout) ->
    exit(Promise, normal),
    case is_process_alive(Promise) of
        false ->
            ok;
        true ->
            _ = async:settle(Promise, #{timeout => Timeout}),
            unlink(Promise),
            exit(Promise, kill),
            %% This makes sure the process has been killed before returning
            is_process_alive(Promise),
            ok
    end.

-spec format_error(Reason, StackTrace) -> ErrorMap when
    Reason :: term(),
    StackTrace :: [term()],
    ErrorMap :: #{pos_integer() => unicode:chardata()}.

format_error(badarg, [{?MODULE, _, [_BadPromise], Info} | _]) ->
    ErrorInfoMap = proplists:get_value(error_info, Info, #{}),
    Cause = maps:get(cause, ErrorInfoMap, none),
    case Cause of
        not_promise -> #{1 => <<"not a promise">>};
        dead_process -> #{1 => <<"dead process">>}
    end;
format_error(_, _) ->
    #{}.

%% @private
start_loop(Result) ->
    Parent = get('$parent'),
    %% Empty the process dictionary to try to reduce the memory footprint as
    %% much as possible.
    erase(),
    case Parent of
        undefined -> ok;
        _ -> put('$parent', Parent)
    end,
    %% Marker for is_promise/1 above
    case Result of
        {value, _} -> put('$promise', succeeded);
        _ -> put('$promise', failed)
    end,
    process_flag(trap_exit, true),
    loop(Result).

%% @private
loop(Result) ->
    receive
        {await, From} ->
            From ! {fulfilled, Result},
            loop(Result);
        {'EXIT', _From, normal} ->
            ok;
        {'EXIT', _From, Reason} ->
            exit(Reason)
    after ?HIBERNATE_AFTER ->
        erlang:hibernate(?MODULE, loop, [Result])
    end.
