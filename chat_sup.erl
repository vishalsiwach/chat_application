-module(chat_sup).
-behaviour(supervisor).

-export([start_link/2]).
-export([init/1]).

start_link(MaxClients, AdminList) ->
   supervisor:start_link({local, ?MODULE}, ?MODULE, {MaxClients, AdminList}).

init({MaxClients, AdminList}) ->
   ServerChild =
       #{id => chat_server,
         start => {chat_server, start_link, [MaxClients, AdminList]},
         restart => permanent,
         shutdown => 5000,
         type => worker,
         modules => [chat_server]},

   ClientSupChild =
       #{id => chat_client_sup,
         start => {chat_client_sup, start_link, []},
         restart => permanent,
         shutdown => 5000,
         type => supervisor,
         modules => [chat_client_sup]},

   ListenerChild =
       #{id => chat_listener,
         start => {chat_listener, start_link, []},
         restart => permanent,
         shutdown => 5000,
         type => worker,
         modules => [chat_listener]},

   {ok, {{one_for_all, 5, 10}, [ServerChild, ClientSupChild, ListenerChild]}}.
