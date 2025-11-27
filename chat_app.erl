-module(chat_app).
-export([start/0, start/1, start/2, stop/0]).

start() ->
    %% default: 100 max clients, no predefined admins
    start(100, []).

start(MaxClients) ->
    start(MaxClients, []).

start(MaxClients, AdminList) when is_integer(MaxClients),
                                  MaxClients > 0,
                                  is_list(AdminList) ->
    io:format("[APP] Starting chat system with max ~p clients.~n", [MaxClients]),
    chat_sup:start_link(MaxClients, AdminList).

stop() ->
    case whereis(chat_sup) of
        undefined ->
            ok;
        Pid ->
            exit(Pid, shutdown),
            ok
    end.
