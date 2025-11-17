-module(chat_server).
-export([start/1, stop/0]).

-define(PORT, 4000).
-define(HISTORY_SIZE, 5). 

% Export dynamically spawned functions for compiler visibility
-export([listen_loop/1, accept_loop/2, client_handler/2, server_state_loop/5, handler_loop/3, parse_message/1, show_clients/0, show_history/0]).

start(MaxClients) ->
    io:format("[SERVER] Starting main server state process...~n"),
    % start server state with initial topic
    ServerPid = spawn(fun() -> server_state_loop(MaxClients, 0, #{}, [], "No topic set") end),
    register(chat_server_registry, ServerPid), 
    io:format("[SERVER] Starting acceptor process, linking to state manager ~p...~n", [ServerPid]),
    spawn(fun() -> listen_loop(ServerPid) end),
    io:format("[SERVER] Server fully initialized. Type 'clients' or 'history' in this shell.~n").

stop() ->
    io:format("[SERVER] Stop functionality not fully implemented.~n").

broadcast_message(ClientsMap, _Sender, Msg, _History) ->
    maps:foreach(
        fun(_Username, {_Pid, Socket}) ->
            gen_tcp:send(Socket, Msg)
        end,
        ClientsMap
    ).

% The core state management loop (now includes Topic)
server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic) ->
    receive
        {io_reply, FromPid, Result} ->
            case Result of
                {ok, "history\n"} -> 
                    io:format("~n--- Chat History ---~n"),
                    lists:foreach(
                        fun({_Timestamp, Sender, Msg}) -> io:format("~s: ~s", [Sender, Msg]) end, 
                        History
                    ),
                    io:format("--------------------~n");
                {ok, "clients\n"} ->
                    io:format("~n--- Connected Clients ---~n"),
                    maps:foreach(
                        fun(Username, {_Pid, _Socket}) -> io:format("~s~n", [Username]) end,
                        ClientsMap
                    ),
                    io:format("-------------------------~n");
                _ -> io:format("Unknown server command.~n")
            end,
            spawn(fun() -> io:read(FromPid, "") end),
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic);

        % Client registration request with a username
        {register_request, FromPid, Socket, Username} ->

            case maps:is_key(Username, ClientsMap) of
                true ->
                    FromPid ! {register_response, {username_taken, Username}},
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic);
                false when CurrentCount < MaxClients ->
                    NewMap = maps:put(Username, {FromPid, Socket}, ClientsMap),
                    NewCount = CurrentCount + 1,

                    % Send current topic to the new client
                    gen_tcp:send(Socket, io_lib:format("[System] Current Topic: ~s~n", [Topic])),

                    % Send history to the new client
                    lists:foreach(
                        fun({_T, _S, Msg}) -> gen_tcp:send(Socket, io_lib:format("[HISTORY] ~s", [Msg])) end,
                        History
                    ),
                    
                    FromPid ! {register_response, ok},
                    EntryMsg = io_lib:format("[System] ~s has joined the chat.~n", [Username]),
                    broadcast_message(NewMap, system, EntryMsg, History),

                    server_state_loop(MaxClients, NewCount, NewMap, History, Topic);
                false -> % Server full
                    FromPid ! {register_response, full},
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic)
            end;

        % Client broadcast message
        {broadcast, SenderUsername, Message} ->
            FormattedMsg = io_lib:format("[~s] ~s", [SenderUsername, Message]),
            
            Timestamp = erlang:system_time(second),
            NewHistoryItem = {Timestamp, SenderUsername, FormattedMsg},
            NewHistory = lists:sublist(History ++ [NewHistoryItem], ?HISTORY_SIZE),
            
            broadcast_message(ClientsMap, broadcast, FormattedMsg, NewHistory),

            server_state_loop(MaxClients, CurrentCount, ClientsMap, NewHistory, Topic); 
        
        {private_message, SenderUsername, ReceiverUsername, Message} ->
            FormattedMsg = io_lib:format("[Private from ~s] ~s", [SenderUsername, Message]),
            
            % Use maps:find/2 to safely check if the receiver exists
            case maps:find(ReceiverUsername, ClientsMap) of
                {ok, {_RecvPid, Socket}} ->
                    % Receiver found, send the message to their socket
                    gen_tcp:send(Socket, FormattedMsg);
                error -> 
                    % Receiver not found, send error back to the sender
                    case maps:find(SenderUsername, ClientsMap) of
                        {ok, {_SendPid, SenderSocket}} -> 
                            gen_tcp:send(SenderSocket, io_lib:format("[System] User ~s not found or offline.~n", [ReceiverUsername]));
                        error ->
                            ok
                    end
            end,
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic);
            
        % Client requests user list
        {get_users, FromPid, _SenderUsername} -> 
            Usernames = maps:keys(ClientsMap),
            FromPid ! {users_list, Usernames},
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic);

        % Client requests the current topic
        {get_topic, FromPid} ->
            FromPid ! {topic_response, Topic},
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic);

        % Client sets a new topic
        {set_topic, Username, NewTopic} ->
            NewTopicStr = lists:flatten(NewTopic),
            BroadcastMsg = io_lib:format("[System] Topic changed by ~s: ~s~n", [Username, NewTopicStr]),
            broadcast_message(ClientsMap, system, BroadcastMsg, History),
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, NewTopicStr);

        % Client disconnects
        {unregister_request, Username} ->
            case maps:take(Username, ClientsMap) of
                {{_Pid, _Socket}, RemainingMap} ->
                    NewCount = CurrentCount - 1,
                    ExitMsg = io_lib:format("[System] ~s has left the chat.~n", [Username]),
                    broadcast_message(RemainingMap, system, ExitMsg, History),
                    server_state_loop(MaxClients, NewCount, RemainingMap, History, Topic);
                error ->
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic)
            end;

        _Other ->
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic)
    after 1000 ->
        spawn(fun() -> io:read(self(), "") end),
        server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic)
    end.


% Acceptor/Handler functions

listen_loop(ServerPid) ->
    {ok, ListenSocket} = gen_tcp:listen(?PORT, [binary, {packet, 0}, {reuseaddr, true}, {active, false}]),
    accept_loop(ListenSocket, ServerPid).

accept_loop(ListenSocket, ServerPid) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            spawn(fun() -> client_handler(Socket, ServerPid) end),
            accept_loop(ListenSocket, ServerPid);
        {error, _Reason} ->
            gen_tcp:close(ListenSocket)
    end.

client_handler(Socket, ServerPid) ->
    HandlerPid = self(),
    gen_tcp:controlling_process(Socket, HandlerPid),
    gen_tcp:send(Socket, "Please enter your username:\n"),
    
    UsernameInput = case gen_tcp:recv(Socket, 0) of
        {ok, Data} -> binary_to_list(Data);
        _ -> ""
    end,
    Username = string:trim(UsernameInput),

    ServerPid ! {register_request, HandlerPid, Socket, Username},
    
    receive
        {register_response, ok} ->
            handler_loop(Socket, ServerPid, Username);
        {register_response, full} ->
            gen_tcp:send(Socket, "Server full. Connection rejected.\n"),
            gen_tcp:close(Socket);
        {register_response, {username_taken, _}} ->
            gen_tcp:send(Socket, io_lib:format("Username ~s is already taken. Connection rejected.\n", [Username])),
            gen_tcp:close(Socket)
    end. 

handler_loop(Socket, ServerPid, Username) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, Data} ->
            Msg = binary_to_list(Data),
            case parse_message(Msg) of
                {broadcast, Text} ->
                    ServerPid ! {broadcast, Username, Text},
                    handler_loop(Socket, ServerPid, Username);
                {private, ToUser, Text} ->
                    ServerPid ! {private_message, Username, ToUser, Text},
                    handler_loop(Socket, ServerPid, Username);
                {get_users} ->
                    ServerPid ! {get_users, self(), Username},
                    receive
                        {users_list, Users} ->
                            gen_tcp:send(Socket, io_lib:format("[System] Connected users: ~p~n", [Users]))
                    end,
                    handler_loop(Socket, ServerPid, Username);
                {get_topic} ->
                    ServerPid ! {get_topic, self()},
                    receive
                        {topic_response, Topic} ->
                            gen_tcp:send(Socket, io_lib:format("[System] Current Topic: ~s~n", [Topic]))
                    end,
                    handler_loop(Socket, ServerPid, Username);
                {set_topic, TopicBin} ->
                    % TopicBin is a binary; convert to list for server storage & broadcast
                    ServerPid ! {set_topic, Username, binary_to_list(TopicBin)},
                    handler_loop(Socket, ServerPid, Username);
                _ ->
                    gen_tcp:send(Socket, "[System] Invalid command. Use: /msg <user> <message>, /users, /topic, or a normal message.\n"),
                    handler_loop(Socket, ServerPid, Username)
            end;
        {error, closed} ->
            ServerPid ! {unregister_request, Username},
            ok;
        {error, _Reason} ->
            gen_tcp:close(Socket),
            ServerPid ! {unregister_request, Username},
            ok
    end.

parse_message(Msg) ->
    Tokens = string:split(string:trim(Msg), " ", all),
    case Tokens of
        ["/msg", ToUser | Text] when length(Text) > 0 -> 
            {private, ToUser, list_to_binary(string:join(Text, " "))};

        ["/users"] -> {get_users};

        ["/topic"] -> {get_topic};

        ["/topic" | TopicWords] ->
            NewTopic = string:join(TopicWords, " "),
            {set_topic, list_to_binary(NewTopic)};

        _ -> {broadcast, list_to_binary(Msg)}
    end.


show_clients() ->
    ServerPid = whereis(chat_server_registry), 
    ServerPid ! {io_reply, self(), {ok, "clients\n"}}.

show_history() ->
    ServerPid = whereis(chat_server_registry),
    ServerPid ! {io_reply, self(), {ok, "history\n"}}.
