-module(chat_client).
-export([start/0, start/1]).

-define(SERVER_IP, {127,0,0,1}).
-define(PORT, 4000).

start() ->
    start(?SERVER_IP).

start(IP) ->
    case gen_tcp:connect(IP, ?PORT, [binary, {packet, 0}, {active, false}]) of
        {ok, Socket} ->
            io:format("Connected to ~p:~p~n", [IP, ?PORT]),
            io:format("Waiting for server prompt for username...~n"),
            gen_tcp:recv(Socket, 0),

            UsernameInput = io:get_line("Enter your username: "),
            Username = string:trim(UsernameInput),
            gen_tcp:send(Socket, list_to_binary(Username ++ "\n")),

            spawn(fun() -> recv_loop(Socket) end), 
            send_loop(Socket); 
        {error, Reason} ->
            io:format("Connection failed: ~p~n", [Reason])
    end.

send_loop(Socket) ->
    case io:get_line("") of
        eof  -> io:format("Client closing.~n"), gen_tcp:close(Socket);
        Line ->
            gen_tcp:send(Socket, list_to_binary(Line)),
            send_loop(Socket)
    end.

recv_loop(Socket) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            io:format("~s", [Data]),
            recv_loop(Socket);
        {error, closed} ->
            io:format("[Server] closed connection.~n"),
            ok;
        {error, Reason} ->
            io:format("[Server] error: ~p~n", [Reason]),
            ok
    end.
