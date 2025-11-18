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
            usage_instructions(),
            send_loop(Socket);
        {error, Reason} ->
            io:format("Connection failed: ~p~n", [Reason])
    end.

send_loop(Socket) ->
    case io:get_line("") of
        eof  ->
            io:format("Client closing.~n"),
            gen_tcp:close(Socket);
        Line ->
            %% trim and append newline if not present
            Trimmed = string:trim(Line),
            gen_tcp:send(Socket, list_to_binary(Trimmed ++ "\n")),
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

usage_instructions() ->
    io:format("Commands available (server-side parsed):~n"),
    io:format(" - Normal message: just type and enter~n"),
    io:format(" - Private: /msg <user> <message>~n"),
    io:format(" - Users list: /users~n"),
    io:format(" - Topic: /topic or /topic <new topic> (admins only to set)~n"),
    io:format(" - Kick (admin): /kick <user>~n"),
    io:format(" - Mute (admin): /mute <user> [5m|30s|300] (default 5m)~n"),
    io:format(" - Unmute (admin): /unmute <user>~n"),
    io:format(" - List admins: /admins~n"),
    io:format(" - Promote (admin): /promote <user>~n"),
    io:format("-----------------------------~n").