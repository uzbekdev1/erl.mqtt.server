%%
%% Copyright (C) 2017 by krasnop@bellsouth.net (Alexei Krasnopolski)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%		 http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License. 
%%

%% @since 2017-01-11
%% @copyright 2017 Alexei Krasnopolski
%% @author Alexei Krasnopolski <krasnop@bellsouth.net> [http://krasnopolski.org/]
%% @version {@version}
%% @doc Main module of the mqtt_server application.


-module(mqtt_server).
-behaviour(application).

-include_lib("mqtt_common/include/mqtt.hrl").

%% ====================================================================
%% API functions
%% ====================================================================
-export([start/2,
	stop/1,
	add_user/2,
	remove_user/1
]).

-define(NUM_ACCEPTORS_IN_POOL, 10).

%% ====================================================================
%% Behavioural functions
%% ====================================================================

%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/apps/kernel/application.html#Module:start-2">application:start/2</a>
%% @private
-spec start(Type :: normal | {takeover, Node} | {failover, Node}, Args :: term()) ->
	{ok, Pid :: pid()}
	| {ok, Pid :: pid(), State :: term()}
	| {error, Reason :: term()}.
%% ====================================================================
start(_Type, _Args) ->
	lager:start(),
	application:load(sasl),
	case application:get_env(lager, log_root) of
		{ok, _} -> ok;
		undefined ->
			application:set_env(lager, log_root, "logs", [{persistent, true}]),
			application:set_env(lager, crash_log, "logs/crash.log", [{persistent, true}]),
			application:set_env(lager, error_logger_redirect, false, [{persistent, true}]),
			application:set_env(lager, handlers, [{lager_console_backend, debug}], [{persistent, true}]),
			application:stop(lager),
			lager:start()
	end,

% for debug >
	A = application:get_all_env(lager),
	lager:debug("lager config env: ~p",[A]),	
	lager:debug("mqtt_server config env: ~p",[application:get_all_env(mqtt_server)]),	
%	< for debug

	Storage =
	case application:get_env(mqtt_server, storage, dets) of
		mysql -> mqtt_mysql_dao;
		dets -> mqtt_dets_dao
	end,
	Storage:start(server),
	Port = application:get_env(mqtt_server, port, 1883),
	Port_tsl = application:get_env(mqtt_server, port_tsl, 1884),
	Cert_File = application:get_env(mqtt_server, certfile, "tsl/server.crt"),
	CA_Cert_File = application:get_env(mqtt_server, cacertfile, "tsl/ca.crt"),
	Key_File = application:get_env(mqtt_server, keyfile, "tsl/server.key"),

	lager:debug("running apps: ~p",[application:which_applications()]),	
%% 	ChildSpec :: {Id :: term(), StartFunc, RestartPolicy, Shutdown, Type :: worker | supervisor, Modules},
%% 	StartFunc :: {M :: module(), F :: atom(), A :: [term()] | undefined},
%% 	RestartPolicy :: permanent
%% 				   | transient
%% 				   | temporary,
%% 	Shutdown :: brutal_kill | timeout(),
%% 	Modules :: [module()] | dynamic.
	RanchSupSpec = {
				ranch_sup, 
				{ranch_sup, start_link, []},
				permanent, 
				5000, 
				supervisor, 
				[ranch_sup]
	},
	TCPListenerSpec = ranch:child_spec(
							mqtt_server, 
							?NUM_ACCEPTORS_IN_POOL,
							ranch_tcp, 
							[{port, Port}], 
							mqtt_server_connection, 
							[{storage, Storage}]
	),
	TSLListenerSpec = ranch:child_spec(
							mqtt_server_tls, 
							?NUM_ACCEPTORS_IN_POOL,
							ranch_ssl, 
							[	{port, Port_tsl},
								{certfile, Cert_File},
								{cacertfile, CA_Cert_File},
								{keyfile, Key_File},
								{verify, verify_peer}
							], 
							mqtt_server_connection, 
							[{storage, Storage}]
        ),
	mqtt_server_sup:start_link([RanchSupSpec, TCPListenerSpec, TSLListenerSpec]).

%% ====================================================================
%% @doc <a href="http://www.erlang.org/doc/apps/kernel/application.html#Module:stop-1">application:stop/1</a>
-spec stop(State :: term()) ->  Any :: term().
%% ====================================================================
%% @private
stop(_State) ->
	ok = ranch:stop_listener(mqtt_server),
	ok = ranch:stop_listener(mqtt_server_tls).

%% ====================================================================
%% API functions
%% ====================================================================
-spec add_user(User :: string(), Password :: binary()) -> term().
% @doc Add user and password pair to USER DB (DETS or MySQL).
add_user(User, Password) ->
	U = if
		is_binary(User) -> binary_to_list(User);
		is_list(User) -> User;
		true -> User
	end,
	P = if
		is_binary(Password) -> Password;
		is_list(Password) -> binary_to_list(Password);
		true -> Password
	end,
	application:load(mqtt_server),
	Storage =
	case application:get_env(mqtt_server, storage, dets) of
		mysql -> mqtt_mysql_dao;
		dets -> mqtt_dets_dao
	end,
	Storage:start(server),
	Storage:save(server, #user{user_id = U, password = P}).

-spec remove_user(User :: string()) -> term().
% @doc Remove user from USER DB (DETS or MySQL).
remove_user(User) ->
	U = if
		is_binary(User) -> binary_to_list(User);
		is_list(User) -> User;
		true -> User
	end,
	application:load(mqtt_server),
	Storage =
	case application:get_env(mqtt_server, storage, dets) of
		mysql -> mqtt_mysql_dao;
		dets -> mqtt_dets_dao
	end,
	Storage:start(server),
	Storage:remove(server, {user_id, U}).

%% ====================================================================
%% Internal functions
%% ====================================================================
