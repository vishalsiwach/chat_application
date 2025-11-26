-module(div3_checker).
-behaviour(gen_statem).

%% API
-export([start_link/0, process_digit/2, is_divisible/1, stop/1]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, Remainder/3]).

%% States
-define(REMAINDER_0, 0).
-define(REMAINDER_1, 1).
-define(REMAINDER_2, 2).

%% API Functions

start_link() ->
    gen_statem:start_link({local, ?MODULE}, ?MODULE, [], []).

process_digit(Pid, Digit) when Digit == $0$ orelse Digit == $1$ ->
    gen_statem:cast(Pid, {new_digit, Digit});
process_digit(_Pid, Digit) ->
    io:format("Error: Invalid input digit ~p~n", [Digit]).

is_divisible(Pid) ->
    gen_statem:call(Pid, get_status).

stop(Pid) ->
    gen_statem:stop(Pid).


callback_mode() -> [state_functions, state_enter].

init(_Args) ->
    {ok, ?REMAINDER_0, []}.

Remainder(EventContent, State, Data) ->
    case EventContent of
        {call, From, get_status} ->
            Reply = (State == ?REMAINDER_0),
            {keep_state_and_data, {reply, From, Reply}};
        {cast, {new_digit, Digit}} ->
            NewState = calculate_new_remainder(State, Digit),
            {next_state, NewState, Data};
        _Other ->
            {keep_state_and_data, {stop, normal}}
    end.

calculate_new_remainder(CurrentRemainder, Digit) ->
    Value = case Digit of
        $0$ -> 0;
        $1$ -> 1
    end,
    (2 * CurrentRemainder + Value) rem 3.

