-module(chat_listener).
-behaviour(gen_server).

-define(PORT, 4000).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    {ok, ListenSocket} =
        gen_tcp:listen(?PORT,
                       [binary,
                        {packet, 0},
                        {reuseaddr, true},
                        {active, false}]),
    io:format("[LISTENER] Listening on port ~p~n", [?PORT]),
    %% Kick off first accept
    self() ! accept,
    {ok, #{listen_socket => ListenSocket}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(accept, State = #{listen_socket := ListenSocket}) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format("[LISTENER] Accepted new connection.~n", []),
            case chat_client_sup:start_client(Socket) of
                {ok, Pid} ->
                    ok = gen_tcp:controlling_process(Socket, Pid),
                    Pid ! start,
                    self() ! accept,
                    {noreply, State};
                {error, Reason} ->
                    io:format("[LISTENER] Failed to start client handler: ~p~n",
                              [Reason]),
                    gen_tcp:close(Socket),
                    self() ! accept,
                    {noreply, State}
            end;
        {error, Reason} ->
            io:format("[LISTENER] accept failed: ~p~n", [Reason]),
            {stop, Reason, State}
    end;

handle_info(_Other, State) ->
    {noreply, State}.

terminate(_Reason, #{listen_socket := ListenSocket}) ->
    gen_tcp:close(ListenSocket),
    ok;
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
