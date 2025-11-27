-module(chat_client_handler).
-behaviour(gen_server).

-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2, code_change/3]).

-record(state, {
    socket,
    username = undefined
}).

start_link(Socket) ->
    gen_server:start_link(?MODULE, Socket, []).

init(Socket) ->
    %% Listener will transfer controlling process and then send us 'start'
    {ok, #state{socket = Socket}}.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

%% After listener says 'start', ask for username
handle_info(start, State=#state{socket=Socket, username=undefined}) ->
    gen_tcp:send(Socket, "Please enter your username:\n"),
    inet:setopts(Socket, [{active, once}]),
    {noreply, State};

%% First TCP packet: username
handle_info({tcp, Socket, Data},
            State=#state{socket=Socket, username=undefined}) ->
    UsernameInput = binary_to_list(Data),
    Username = string:trim(UsernameInput),
    case chat_server:register_client(self(), Socket, Username) of
        ok ->
            inet:setopts(Socket, [{active, once}]),
            {noreply, State#state{username = Username}};
        {error, full} ->
            gen_tcp:send(Socket, "Server full. Connection rejected.\n"),
            gen_tcp:close(Socket),
            {stop, normal, State};
        {error, username_taken} ->
            gen_tcp:send(
              Socket,
              io_lib:format(
                "Username ~s is already taken. Connection rejected.\n",
                [Username])),
            gen_tcp:close(Socket),
            {stop, normal, State}
    end;

%% Normal chat messages
handle_info({tcp, Socket, Data},
            State=#state{socket=Socket, username=Username}) ->
    Msg = binary_to_list(Data),
    case parse_message(Msg) of
        {broadcast, Text} ->
            chat_server:broadcast(Username, Text);
        {private, ToUser, Text} ->
            chat_server:private_message(Username, ToUser, Text);
        {get_users} ->
            Users = chat_server:get_users(),
            gen_tcp:send(
              Socket,
              io_lib:format("[System] Connected users: ~p~n", [Users]));
        {get_topic} ->
            Topic = chat_server:get_topic(),
            gen_tcp:send(
              Socket,
              io_lib:format("[System] Current Topic: ~s~n", [Topic]));
        {set_topic, TopicBin} ->
            chat_server:set_topic(Username, binary_to_list(TopicBin));
        {kick, Target} ->
            chat_server:kick(Username, Target);
        {mute, Target, Secs} ->
            chat_server:mute(Username, Target, Secs);
        {unmute, Target} ->
            chat_server:unmute(Username, Target);
        {get_admins} ->
            Admins = chat_server:get_admins(),
            gen_tcp:send(
              Socket,
              io_lib:format("[System] Admin users: ~p~n", [Admins]));
        {promote, Target} ->
            chat_server:promote(Username, Target);
        _ ->
            gen_tcp:send(
              Socket,
              "[System] Invalid command. Use: /msg <user> <message>, "
              "/users, /topic, /kick, /mute, /unmute, /admins, /promote, "
              "or a normal message.\n")
    end,
    inet:setopts(Socket, [{active, once}]),
    {noreply, State};

handle_info({tcp_closed, Socket},
            State=#state{socket=Socket, username=Username}) ->
    io:format("[CLIENT] ~p closed connection.~n", [Username]),
    case Username of
        undefined -> ok;
        _ -> chat_server:unregister_client(Username)
    end,
    {stop, normal, State};

handle_info({tcp_error, Socket, Reason},
            State=#state{socket=Socket, username=Username}) ->
    io:format("[CLIENT] ~p socket error: ~p~n", [Username, Reason]),
    case Username of
        undefined -> ok;
        _ -> chat_server:unregister_client(Username)
    end,
    gen_tcp:close(Socket),
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{socket=Socket}) ->
    catch gen_tcp:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Parsing helpers (from your original code)

parse_message(Msg) ->
    Trim = string:trim(Msg),
    Tokens = string:split(Trim, " ", all),
    case Tokens of
        ["/msg", ToUser | Text] when length(Text) > 0 ->
            {private, ToUser, list_to_binary(string:join(Text, " "))};
        ["/users"] ->
            {get_users};
        ["/topic"] ->
            {get_topic};
        ["/topic" | TopicWords] ->
            NewTopic = string:join(TopicWords, " "),
            {set_topic, list_to_binary(NewTopic)};
        ["/kick", Target] ->
            {kick, Target};
        ["/mute", Target, DurationStr] ->
            {ok, Secs} = parse_duration(DurationStr),
            {mute, Target, Secs};
        ["/mute", Target] ->
            {mute, Target, 300};
        ["/unmute", Target] ->
            {unmute, Target};
        ["/admins"] ->
            {get_admins};
        ["/promote", Target] ->
            {promote, Target};
        _ ->
            {broadcast, list_to_binary(Msg)}
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
        {Int, _Rest} ->
            {ok, Int}
    end.
