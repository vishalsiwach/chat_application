-module(chat_client_sup).
-behaviour(supervisor).

-export([start_link/0, start_client/1]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_client(Socket) ->
    supervisor:start_child(?MODULE, [Socket]).

init([]) ->
    ClientChild =
        #{id => chat_client_handler,
          start => {chat_client_handler, start_link, []},
          restart => transient,
          shutdown => 5000,
          type => worker,
          modules => [chat_client_handler]},
    {ok, {{simple_one_for_one, 5, 10}, [ClientChild]}}.
