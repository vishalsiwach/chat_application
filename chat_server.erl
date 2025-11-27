-module(chat_server).
-behaviour(gen_server).

-define(HISTORY_SIZE, 5).

-export([
    start_link/2, stop/0,
    register_client/3, unregister_client/1,
    broadcast/2, private_message/3,
    get_users/0, get_topic/0, set_topic/2,
    kick/2, mute/3, unmute/2,
    get_admins/0, promote/2,
    show_clients/0, show_history/0, show_admins/0
]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(state, {
    max_clients,
    current_count = 0,
    clients = #{},     %% Username => {Pid, Socket}
    history = [],
    topic = "No topic set",
    admins = sets:new(),
    mutes = #{}        %% Username => UnmuteAt (second)
}).

%%% Public API

start_link(MaxClients, AdminList) ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, {MaxClients, AdminList}, []).

stop() ->
    gen_server:cast(?MODULE, stop).

%% called by chat_client_handler
register_client(Pid, Socket, Username) ->
    gen_server:call(?MODULE, {register, Pid, Socket, Username}).

unregister_client(Username) ->
    gen_server:cast(?MODULE, {unregister, Username}).

broadcast(Sender, MessageBin) ->
    gen_server:cast(?MODULE, {broadcast, Sender, MessageBin}).

private_message(Sender, Receiver, MessageBin) ->
    gen_server:cast(?MODULE, {private, Sender, Receiver, MessageBin}).

get_users() ->
    gen_server:call(?MODULE, get_users).

get_topic() ->
    gen_server:call(?MODULE, get_topic).

set_topic(Username, NewTopic) ->
    gen_server:cast(?MODULE, {set_topic, Username, NewTopic}).

kick(AdminUsername, TargetUsername) ->
    gen_server:cast(?MODULE, {kick, AdminUsername, TargetUsername}).

mute(AdminUsername, TargetUsername, DurationSecs) ->
    gen_server:cast(?MODULE, {mute, AdminUsername, TargetUsername, DurationSecs}).

unmute(AdminUsername, TargetUsername) ->
    gen_server:cast(?MODULE, {unmute, AdminUsername, TargetUsername}).

get_admins() ->
    gen_server:call(?MODULE, get_admins).

promote(AdminUsername, TargetUsername) ->
    gen_server:cast(?MODULE, {promote, AdminUsername, TargetUsername}).

%% Shell helpers (like your original show_*)

show_clients() ->
    gen_server:call(?MODULE, show_clients).

show_history() ->
    gen_server:call(?MODULE, show_history).

show_admins() ->
    gen_server:call(?MODULE, show_admins).

%%% gen_server callbacks

init({MaxClients, AdminList}) ->
    io:format("[SERVER] Starting main server state process with max ~p clients...~n",
              [MaxClients]),
    AdminsSet = sets:from_list(AdminList),
    State0 = #state{
        max_clients = MaxClients,
        admins = AdminsSet
    },
    %% periodic tick for auto-unmute
    erlang:send_after(1000, self(), tick),
    {ok, State0}.

%% --- synchronous calls ---

handle_call({register, Pid, Socket, Username}, _From,
            State=#state{max_clients=Max,
                         current_count=CurrentCount,
                         clients=Clients,
                         history=History,
                         topic=Topic}) ->
    case maps:is_key(Username, Clients) of
        true ->
            {reply, {error, username_taken}, State};
        false when CurrentCount < Max ->
            NewClients = maps:put(Username, {Pid, Socket}, Clients),
            NewCount = CurrentCount + 1,
            %% Send current topic to the new client
            gen_tcp:send(Socket,
                         io_lib:format("[System] Current Topic: ~s~n", [Topic])),
            %% Send history to the new client
            lists:foreach(
              fun({_T, _S, Msg}) ->
                      gen_tcp:send(Socket,
                                   io_lib:format("[HISTORY] ~s", [Msg]))
              end,
              History),
            EntryMsg = io_lib:format("[System] ~s has joined the chat.~n",
                                     [Username]),
            broadcast_message(NewClients, EntryMsg),
            {reply, ok,
             State#state{current_count = NewCount,
                         clients = NewClients}};
        false ->
            {reply, {error, full}, State}
    end;

handle_call(get_users, _From, State=#state{clients=Clients}) ->
    {reply, maps:keys(Clients), State};

handle_call(get_topic, _From, State=#state{topic=Topic}) ->
    {reply, Topic, State};

handle_call(get_admins, _From, State=#state{admins=Admins}) ->
    {reply, sets:to_list(Admins), State};

%% Shell helper calls: print and return ok

handle_call(show_clients, _From, State=#state{clients=Clients}) ->
    io:format("~n--- Connected Clients ---~n"),
    maps:foreach(
      fun(Username, {_Pid, _Socket}) ->
              io:format("~s~n", [Username])
      end,
      Clients),
    io:format("-------------------------~n"),
    {reply, ok, State};

handle_call(show_history, _From, State=#state{history=History}) ->
    io:format("~n--- Chat History ---~n"),
    lists:foreach(
      fun({_Timestamp, Sender, Msg}) ->
              io:format("~s: ~s", [Sender, Msg])
      end,
      History),
    io:format("--------------------~n"),
    {reply, ok, State};

handle_call(show_admins, _From, State=#state{admins=Admins}) ->
    io:format("~n--- Admin Users ---~n"),
    lists:foreach(
      fun(A) -> io:format("~s~n", [A]) end,
      sets:to_list(Admins)),
    io:format("------------------~n"),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%% --- async casts (state changes) ---

handle_cast(stop, State) ->
    {stop, normal, State};

handle_cast({unregister, Username},
            State=#state{clients=Clients, current_count=CurrentCount}) ->
    case maps:take(Username, Clients) of
        {{_Pid, _Socket}, RemainingMap} ->
            ExitMsg = io_lib:format("[System] ~s has left the chat.~n",
                                    [Username]),
            broadcast_message(RemainingMap, ExitMsg),
            NewState = State#state{
                        clients = RemainingMap,
                        current_count = CurrentCount - 1
                       },
            {noreply, NewState};
        error ->
            {noreply, State}
    end;

handle_cast({broadcast, SenderUsername, Message},
            State=#state{clients=Clients,
                         history=History,
                         mutes=Mutes}) ->
    Now = erlang:system_time(second),
    case maps:find(SenderUsername, Mutes) of
        {ok, UnmuteAt} when UnmuteAt > Now ->
            %% muted -> inform sender only
            case maps:find(SenderUsername, Clients) of
                {ok, {_Pid, SenderSocket}} ->
                    Remaining = UnmuteAt - Now,
                    Human = human_readable_secs(Remaining),
                    gen_tcp:send(
                      SenderSocket,
                      io_lib:format(
                        "[System] You are muted for ~s more.~n", [Human]));
                error -> ok
            end,
            {noreply, State};
        _ ->
            FormattedMsg = io_lib:format("[~s] ~s", [SenderUsername, Message]),
            Timestamp = Now,
            NewHistoryItem = {Timestamp, SenderUsername, FormattedMsg},
            NewHistory = lists:sublist(History ++ [NewHistoryItem],
                                       ?HISTORY_SIZE),
            broadcast_message(Clients, FormattedMsg),
            {noreply, State#state{history = NewHistory}}
    end;

handle_cast({private, SenderUsername, ReceiverUsername, Message},
            State=#state{clients=Clients}) ->
    FormattedMsg =
        io_lib:format("[Private from ~s] ~s", [SenderUsername, Message]),
    case maps:find(ReceiverUsername, Clients) of
        {ok, {_RecvPid, Socket}} ->
            gen_tcp:send(Socket, FormattedMsg);
        error ->
            case maps:find(SenderUsername, Clients) of
                {ok, {_SendPid, SenderSocket}} ->
                    gen_tcp:send(
                      SenderSocket,
                      io_lib:format(
                        "[System] User ~s not found or offline.~n",
                        [ReceiverUsername]));
                error -> ok
            end
    end,
    {noreply, State};

handle_cast({set_topic, Username, NewTopic},
            State=#state{clients=Clients, admins=Admins}) ->
    case sets:is_element(Username, Admins) of
        true ->
            NewTopicStr = lists:flatten(NewTopic),
            BroadcastMsg =
                io_lib:format("[System] Topic changed by ~s: ~s~n",
                              [Username, NewTopicStr]),
            broadcast_message(Clients, BroadcastMsg),
            {noreply, State#state{topic = NewTopicStr}};
        false ->
            case maps:find(Username, Clients) of
                {ok, {_Pid, Socket}} ->
                    gen_tcp:send(
                      Socket,
                      "[System] Only admins can change topic.\n");
                error -> ok
            end,
            {noreply, State}
    end;

handle_cast({kick, AdminUsername, TargetUsername},
            State=#state{clients=Clients,
                         admins=Admins,
                         current_count=CurrentCount}) ->
    case sets:is_element(AdminUsername, Admins) of
        true ->
            case maps:find(TargetUsername, Clients) of
                {ok, {_TargetPid, TargetSocket}} ->
                    gen_tcp:send(
                      TargetSocket,
                      io_lib:format(
                        "[System] You were kicked by ~s.~n",
                        [AdminUsername])),
                    gen_tcp:close(TargetSocket),
                    {_Removed, RemainingMap} =
                        maps:take(TargetUsername, Clients),
                    NewCount = CurrentCount - 1,
                    ExitMsg = io_lib:format(
                                "[System] ~s was kicked by ~s.~n",
                                [TargetUsername, AdminUsername]),
                    broadcast_message(RemainingMap, ExitMsg),
                    {noreply,
                     State#state{clients=RemainingMap,
                                 current_count=NewCount}};
                error ->
                    case maps:find(AdminUsername, Clients) of
                        {ok, {_Pid, Socket}} ->
                            gen_tcp:send(
                              Socket,
                              io_lib:format(
                                "[System] User ~s not found or offline.~n",
                                [TargetUsername]));
                        error -> ok
                    end,
                    {noreply, State}
            end;
        false ->
            case maps:find(AdminUsername, Clients) of
                {ok, {_Pid, Socket}} ->
                    gen_tcp:send(Socket,
                                 "[System] You are not an admin.\n");
                error -> ok
            end,
            {noreply, State}
    end;

handle_cast({mute, AdminUsername, TargetUsername, DurationSecs},
            State=#state{clients=Clients,
                         admins=Admins,
                         mutes=Mutes}) ->
    case sets:is_element(AdminUsername, Admins) of
        true ->
            Now = erlang:system_time(second),
            UnmuteAt = Now + DurationSecs,
            NewMutes = maps:put(TargetUsername, UnmuteAt, Mutes),
            BroadcastMsg =
                io_lib:format(
                  "[System] ~s has been muted by ~s until ~p.~n",
                  [TargetUsername, AdminUsername, UnmuteAt]),
            broadcast_message(Clients, BroadcastMsg),
            {noreply, State#state{mutes = NewMutes}};
        false ->
            case maps:find(AdminUsername, Clients) of
                {ok, {_Pid, Socket}} ->
                    gen_tcp:send(Socket,
                                 "[System] You are not an admin.\n");
                error -> ok
            end,
            {noreply, State}
    end;

handle_cast({unmute, AdminUsername, TargetUsername},
            State=#state{clients=Clients,
                         admins=Admins,
                         mutes=Mutes}) ->
    case sets:is_element(AdminUsername, Admins) of
        true ->
            case maps:is_key(TargetUsername, Mutes) of
                true ->
                    NewMutes2 = maps:remove(TargetUsername, Mutes),
                    BroadcastMsg =
                        io_lib:format(
                          "[System] ~s has been unmuted by ~s.~n",
                          [TargetUsername, AdminUsername]),
                    broadcast_message(Clients, BroadcastMsg),
                    {noreply, State#state{mutes = NewMutes2}};
                false ->
                    case maps:find(AdminUsername, Clients) of
                        {ok, {_Pid, Socket}} ->
                            gen_tcp:send(
                              Socket,
                              io_lib:format(
                                "[System] User ~s is not muted.~n",
                                [TargetUsername]));
                        error -> ok
                    end,
                    {noreply, State}
            end;
        false ->
            case maps:find(AdminUsername, Clients) of
                {ok, {_Pid, Socket}} ->
                    gen_tcp:send(Socket,
                                 "[System] You are not an admin.\n");
                error -> ok
            end,
            {noreply, State}
    end;

handle_cast({promote, AdminUsername, TargetUsername},
            State=#state{clients=Clients, admins=Admins}) ->
    case sets:is_element(AdminUsername, Admins) of
        true ->
            NewAdmins = sets:add_element(TargetUsername, Admins),
            BroadcastMsg =
                io_lib:format(
                  "[System] ~s has been promoted to admin by ~s.~n",
                  [TargetUsername, AdminUsername]),
            broadcast_message(Clients, BroadcastMsg),
            {noreply, State#state{admins = NewAdmins}};
        false ->
            case maps:find(AdminUsername, Clients) of
                {ok, {_Pid, Socket}} ->
                    gen_tcp:send(Socket,
                                 "[System] You are not an admin.\n");
                error -> ok
            end,
            {noreply, State}
    end;

handle_cast(_Other, State) ->
    {noreply, State}.

%% --- info: periodic tasks ---

handle_info(tick, State=#state{mutes=Mutes, clients=Clients}) ->
    Now = erlang:system_time(second),
    Expired =
        [User || {User, UnmuteAt} <- maps:to_list(Mutes),
                 UnmuteAt =< Now],
    NewMutes =
        lists:foldl(fun(U, Acc) -> maps:remove(U, Acc) end,
                    Mutes,
                    Expired),
    lists:foreach(
      fun(U) ->
              BroadcastMsg =
                  io_lib:format(
                    "[System] ~s has been automatically unmuted.~n",
                    [U]),
              broadcast_message(Clients, BroadcastMsg)
      end,
      Expired),
    erlang:send_after(1000, self(), tick),
    {noreply, State#state{mutes = NewMutes}};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal helpers

broadcast_message(ClientsMap, Msg) ->
    maps:foreach(
      fun(_Username, {_Pid, Socket}) ->
              gen_tcp:send(Socket, Msg)
      end,
      ClientsMap).

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
