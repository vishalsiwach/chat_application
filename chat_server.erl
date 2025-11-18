-module(chat_server).
-export([start/1, start/2, stop/0]).

-define(PORT, 4000).
-define(HISTORY_SIZE, 5). 

-export([listen_loop/1, accept_loop/2, client_handler/2, server_state_loop/7, handler_loop/3, parse_message/1, show_clients/0, show_history/0, show_admins/0]).

start(MaxClients) ->
    start(MaxClients, []).

start(MaxClients, AdminList) when is_list(AdminList) ->
    io:format("[SERVER] Starting main server state process with max ~p clients...~n", [MaxClients]),
    AdminsSet = sets:from_list(AdminList),
    ServerPid = spawn(fun() ->
        server_state_loop(MaxClients, 0, #{}, [], "No topic set", AdminsSet, #{})
    end),
    register(chat_server_registry, ServerPid),
    io:format("[SERVER] Starting acceptor process, linked to state manager ~p...~n", [ServerPid]),
    spawn(fun() -> listen_loop(ServerPid) end),
    io:format("[SERVER] Server fully initialized. Type 'clients', 'history' or 'admins' in this shell.~n").

stop() ->
    io:format("[SERVER] Stop functionality not fully implemented.~n").

broadcast_message(ClientsMap, _Sender, Msg) ->
    maps:foreach(
        fun(_Username, {_Pid, Socket}) ->
            gen_tcp:send(Socket, Msg)
        end,
        ClientsMap
    ).

server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes) ->
    receive
        {io_reply, FromPid, Result} ->
            case Result of
                {ok, "history\n"} ->
                    io:format("~n--- Chat History ---~n"),
                    lists:foreach(
                      fun({_Timestamp, Sender, Msg}) -> io:format("~s: ~s", [Sender, Msg]) end,
                      History),
                    io:format("--------------------~n");
                {ok, "clients\n"} ->
                    io:format("~n--- Connected Clients ---~n"),
                    maps:foreach(fun(Username, {_Pid, _Socket}) -> io:format("~s~n", [Username]) end, ClientsMap),
                    io:format("-------------------------~n");
                {ok, "admins\n"} ->
                    io:format("~n--- Admin Users ---~n"),
                    lists:foreach(fun(A) -> io:format("~s~n", [A]) end, sets:to_list(Admins)),
                    io:format("------------------~n");
                _ -> io:format("Unknown server command.~n")
            end,
            spawn(fun() -> io:read(FromPid, "") end),
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);

        % Client registration request
        {register_request, FromPid, Socket, Username} ->
            case maps:is_key(Username, ClientsMap) of
                true ->
                    FromPid ! {register_response, {username_taken, Username}},
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);
                false when CurrentCount < MaxClients ->
                    NewMap = maps:put(Username, {FromPid, Socket}, ClientsMap),
                    NewCount = CurrentCount + 1,
                    %% Send current topic to the new client
                    gen_tcp:send(Socket, io_lib:format("[System] Current Topic: ~s~n", [Topic])),
                    %% Send history to the new client
                    lists:foreach(
                        fun({_T, _S, Msg}) -> gen_tcp:send(Socket, io_lib:format("[HISTORY] ~s", [Msg])) end,
                        History),
                    FromPid ! {register_response, ok},
                    EntryMsg = io_lib:format("[System] ~s has joined the chat.~n", [Username]),
                    broadcast_message(NewMap, system, EntryMsg),
                    server_state_loop(MaxClients, NewCount, NewMap, History, Topic, Admins, Mutes);
                false ->
                    FromPid ! {register_response, full},
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;

        % Broadcast message from a client (public)
        {broadcast, SenderUsername, Message} ->
            Now = erlang:system_time(second),
            case maps:find(SenderUsername, Mutes) of
                {ok, UnmuteAt} when UnmuteAt > Now ->
                    %% Sender is muted -> inform sender only
                    case maps:find(SenderUsername, ClientsMap) of
                        {ok, {_Pid, SenderSocket}} ->
                            Remaining = UnmuteAt - Now,
                            Human = human_readable_secs(Remaining),
                            gen_tcp:send(SenderSocket, io_lib:format("[System] You are muted for ~s more.~n", [Human]));
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);
                _ ->
                    %% Not muted or mute expired - broadcast normally, update history
                    FormattedMsg = io_lib:format("[~s] ~s", [SenderUsername, Message]),
                    Timestamp = Now,
                    NewHistoryItem = {Timestamp, SenderUsername, FormattedMsg},
                    NewHistory = lists:sublist(History ++ [NewHistoryItem], ?HISTORY_SIZE),
                    broadcast_message(ClientsMap, broadcast, FormattedMsg),
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, NewHistory, Topic, Admins, Mutes)
            end;

        % Private message
        {private_message, SenderUsername, ReceiverUsername, Message} ->
            FormattedMsg = io_lib:format("[Private from ~s] ~s", [SenderUsername, Message]),
            case maps:find(ReceiverUsername, ClientsMap) of
                {ok, {_RecvPid, Socket}} ->
                    gen_tcp:send(Socket, FormattedMsg);
                error ->
                    case maps:find(SenderUsername, ClientsMap) of
                        {ok, {_SendPid, SenderSocket}} ->
                            gen_tcp:send(SenderSocket, io_lib:format("[System] User ~s not found or offline.~n", [ReceiverUsername]));
                        error -> ok
                    end
            end,
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);

        % Request user list
        {get_users, FromPid, _SenderUsername} ->
            Usernames = maps:keys(ClientsMap),
            FromPid ! {users_list, Usernames},
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);

        % Request current topic
        {get_topic, FromPid} ->
            FromPid ! {topic_response, Topic},
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);

        % Set new topic
        {set_topic, Username, NewTopic} ->
            case sets:is_element(Username, Admins) of
                true ->
                    NewTopicStr = lists:flatten(NewTopic),
                    BroadcastMsg = io_lib:format("[System] Topic changed by ~s: ~s~n", [Username, NewTopicStr]),
                    broadcast_message(ClientsMap, system, BroadcastMsg),
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, NewTopicStr, Admins, Mutes);

                false ->
                    case maps:find(Username, ClientsMap) of
                        {ok, {_Pid, Socket}} ->
                            gen_tcp:send(Socket, "[System] Only admins can change topic.\n");
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;

        % Kick user (admin command)
        {kick_user, AdminUsername, TargetUsername} ->
            case sets:is_element(AdminUsername, Admins) of
                true ->
                    case maps:find(TargetUsername, ClientsMap) of
                        {ok, {_TargetPid, TargetSocket}} ->
                            gen_tcp:send(TargetSocket, io_lib:format("[System] You were kicked by ~s.~n", [AdminUsername])),
                            gen_tcp:close(TargetSocket),
                            {_Removed, RemainingMap} = maps:take(TargetUsername, ClientsMap),
                            NewCount = CurrentCount - 1,
                            ExitMsg = io_lib:format("[System] ~s was kicked by ~s.~n", [TargetUsername, AdminUsername]),
                            broadcast_message(RemainingMap, system, ExitMsg),
                            server_state_loop(MaxClients, NewCount, RemainingMap, History, Topic, Admins, Mutes);

                        error ->
                            case maps:find(AdminUsername, ClientsMap) of
                                {ok, {_Pid, Socket}} ->
                                    gen_tcp:send(Socket, io_lib:format("[System] User ~s not found or offline.~n", [TargetUsername]));
                                error -> ok
                            end,
                            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
                    end;

                false ->
                    case maps:find(AdminUsername, ClientsMap) of
                        {ok, {_Pid, Socket}} -> gen_tcp:send(Socket, "[System] You are not an admin.\n");
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;


        % Mute user (admin) with duration seconds
        {mute_user, AdminUsername, TargetUsername, DurationSecs} ->
            case sets:is_element(AdminUsername, Admins) of
                true ->
                    Now = erlang:system_time(second),
                    UnmuteAt = Now + DurationSecs,
                    NewMutes = maps:put(TargetUsername, UnmuteAt, Mutes),
                    BroadcastMsg = io_lib:format("[System] ~s has been muted by ~s until ~p.~n", [TargetUsername, AdminUsername, UnmuteAt]),
                    broadcast_message(ClientsMap, system, BroadcastMsg),
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, NewMutes);

                false ->
                    case maps:find(AdminUsername, ClientsMap) of
                        {ok, {_Pid, Socket}} -> gen_tcp:send(Socket, "[System] You are not an admin.\n");
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;


        % Unmute
        {unmute_user, AdminUsername, TargetUsername} ->
            case sets:is_element(AdminUsername, Admins) of
                true ->
                    case maps:is_key(TargetUsername, Mutes) of
                        true ->
                            NewMutes2 = maps:remove(TargetUsername, Mutes),
                            BroadcastMsg = io_lib:format("[System] ~s has been unmuted by ~s.~n", [TargetUsername, AdminUsername]),
                            broadcast_message(ClientsMap, system, BroadcastMsg),
                            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, NewMutes2);

                        false ->
                            case maps:find(AdminUsername, ClientsMap) of
                                {ok, {_Pid, Socket}} ->
                                    gen_tcp:send(Socket, io_lib:format("[System] User ~s is not muted.~n", [TargetUsername]));
                                error -> ok
                            end,
                            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
                    end;

                false ->
                    case maps:find(AdminUsername, ClientsMap) of
                        {ok, {_Pid, Socket}} -> gen_tcp:send(Socket, "[System] You are not an admin.\n");
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;
        % Promote user to admin
        {promote_user, AdminUsername, TargetUsername} ->
            case sets:is_element(AdminUsername, Admins) of
                true ->
                    NewAdmins = sets:add_element(TargetUsername, Admins),
                    BroadcastMsg = io_lib:format("[System] ~s has been promoted to admin by ~s.~n", [TargetUsername, AdminUsername]),
                    broadcast_message(ClientsMap, system, BroadcastMsg),
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, NewAdmins, Mutes);

                false ->
                    case maps:find(AdminUsername, ClientsMap) of
                        {ok, {_Pid, Socket}} -> gen_tcp:send(Socket, "[System] You are not an admin.\n");
                        error -> ok
                    end,
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;


        % Request admins list
        {get_admins, FromPid} ->
            FromPid ! {admins_list, sets:to_list(Admins)},
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);

        % Client disconnects / unregister
        {unregister_request, Username} ->
            case maps:take(Username, ClientsMap) of
                {{_Pid, _Socket}, RemainingMap} ->
                    NewCount = CurrentCount - 1,
                    ExitMsg = io_lib:format("[System] ~s has left the chat.~n", [Username]),
                    broadcast_message(RemainingMap, system, ExitMsg),
                    server_state_loop(MaxClients, NewCount, RemainingMap, History, Topic, Admins, Mutes);
                error ->
                    server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
            end;

        _Other ->
            server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes)
    after 1000 ->
        %% Periodic tasks: auto-unmute expired mutes
        Now = erlang:system_time(second),
        Expired = [User || {User, UnmuteAt} <- maps:to_list(Mutes), UnmuteAt =< Now],
        case Expired of
            [] ->
                spawn(fun() -> io:read(self(), "") end),
                server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, Mutes);
            _ ->
                NewMutes = lists:foldl(fun(U, Acc) -> maps:remove(U, Acc) end, Mutes, Expired),
                lists:foreach(
                    fun(U) ->
                        BroadcastMsg = io_lib:format("[System] ~s has been automatically unmuted.~n", [U]),
                        broadcast_message(ClientsMap, system, BroadcastMsg)
                    end,
                    Expired),
                spawn(fun() -> io:read(self(), "") end),
                server_state_loop(MaxClients, CurrentCount, ClientsMap, History, Topic, Admins, NewMutes)
        end
    end.

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
                    ServerPid ! {set_topic, Username, binary_to_list(TopicBin)},
                    handler_loop(Socket, ServerPid, Username);
                {kick, Target} ->
                    ServerPid ! {kick_user, Username, Target},
                    handler_loop(Socket, ServerPid, Username);
                {mute, Target, Secs} ->
                    ServerPid ! {mute_user, Username, Target, Secs},
                    handler_loop(Socket, ServerPid, Username);
                {unmute, Target} ->
                    ServerPid ! {unmute_user, Username, Target},
                    handler_loop(Socket, ServerPid, Username);
                {get_admins} ->
                    ServerPid ! {get_admins, self()},
                    receive
                        {admins_list, Admins} ->
                            gen_tcp:send(Socket, io_lib:format("[System] Admin users: ~p~n", [Admins]))
                    end,
                    handler_loop(Socket, ServerPid, Username);
                {promote, Target} ->
                    ServerPid ! {promote_user, Username, Target},
                    handler_loop(Socket, ServerPid, Username);
                _ ->
                    gen_tcp:send(Socket, "[System] Invalid command. Use: /msg <user> <message>, /users, /topic, /kick, /mute, /unmute, /admins, /promote, or a normal message.\n"),
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
    Trim = string:trim(Msg),
    Tokens = string:split(Trim, " ", all),
    case Tokens of
        ["/msg", ToUser | Text] when length(Text) > 0 ->
            {private, ToUser, list_to_binary(string:join(Text, " "))};
        ["/users"] -> {get_users};
        ["/topic"] -> {get_topic};
        ["/topic" | TopicWords] ->
            NewTopic = string:join(TopicWords, " "),
            {set_topic, list_to_binary(NewTopic)};
        ["/kick", Target] -> {kick, Target};
        ["/mute", Target, DurationStr] ->
            {ok, Secs} = parse_duration(DurationStr),
            {mute, Target, Secs};
        ["/mute", Target] ->
            {mute, Target, 300};
        ["/unmute", Target] -> {unmute, Target};
        ["/admins"] -> {get_admins};
        ["/promote", Target] -> {promote, Target};
        _ -> {broadcast, list_to_binary(Msg)}
    end.

%% parse duration type strings: "5m", "30s", "300" -> seconds
parse_duration(Str) when is_list(Str) ->
    case string:to_integer(Str) of
        {error, _} ->
            Lower = string:to_lower(Str),
            case re:run(Lower, "^(\\d+)(s|m)$", [{capture, [1,2], list}]) of
                {match, [NumStr, "s"]} ->
                    {ok, _} = string:to_integer(NumStr),
                    {ok, list_to_integer(NumStr)};
                {match, [NumStr, "m"]} ->
                    {ok, _} = string:to_integer(NumStr),
                    {ok, list_to_integer(NumStr) * 60};
                _ ->
                    {error, invalid}
            end;
        {Int, _Rest} -> {ok, Int}
    end.

%% Utilities
human_readable_secs(Seconds) when Seconds >= 3600 ->
    H = Seconds div 3600,
    R = Seconds rem 3600,
    M = R div 60,
    io_lib:format("~p hour(s) and ~p minute(s)", [H, M]);
human_readable_secs(Seconds) when Seconds >= 60 ->
    M = Seconds div 60,
    S = Seconds rem 60,
    io_lib:format("~p minute(s) and ~p second(s)", [M, S]);
human_readable_secs(Seconds) ->
    io_lib:format("~p second(s)", [Seconds]).

show_clients() ->
    ServerPid = whereis(chat_server_registry),
    ServerPid ! {io_reply, self(), {ok, "clients\n"}}.

show_history() ->
    ServerPid = whereis(chat_server_registry),
    ServerPid ! {io_reply, self(), {ok, "history\n"}}.

show_admins() ->
    ServerPid = whereis(chat_server_registry),
    ServerPid ! {io_reply, self(), {ok, "admins\n"}}.