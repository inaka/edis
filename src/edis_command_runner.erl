%%%-------------------------------------------------------------------
%%% @author Fernando Benavides <fernando.benavides@inakanetworks.com>
%%% @author Chad DePue <chad@inakanetworks.com>
%%% @copyright (C) 2011 InakaLabs SRL
%%% @doc edis Command runner.
%%%      It helps pipelining commands and running them in order, thanks to
%%%      regular Erlang mechanisms
%%% @todo Unsupported commands: SYNC, SLOWLOG, SLAVEOF
%%% @end
%%%-------------------------------------------------------------------
-module(edis_command_runner).
-author('Fernando Benavides <fernando.benavides@inakanetworks.com>').
-author('Chad DePue <chad@inakanetworks.com>').

-behaviour(gen_server).

-include("edis.hrl").

-record(state, {socket                  :: port(),
                db = edis_db:process(0) :: atom(),
                peerport                :: pos_integer(),
                authenticated = false   :: boolean()}).
-opaque state() :: #state{}.

-export([start_link/1, stop/1, err/2, run/3]).
-export([last_arg/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% =================================================================================================
%% External functions
%% =================================================================================================
-spec start_link(port()) -> {ok, pid()}.
start_link(Socket) ->
  gen_server:start_link(?MODULE, Socket, []).

-spec stop(pid()) -> ok.
stop(Runner) ->
  gen_server:cast(Runner, stop).

-spec err(pid(), iodata()) -> ok.
err(Runner, Message) ->
  gen_server:cast(Runner, {err, Message}).

-spec run(pid(), binary(), [binary()]) -> ok.
run(Runner, Command, Arguments) ->
  gen_server:cast(Runner, {run, Command, Arguments}).

%% @doc Should last argument be inlined?
%%      Useful for old protocol calls.
-spec last_arg(binary()) -> inlined | safe.
last_arg(_) -> inlined.

%% =================================================================================================
%% Server functions
%% =================================================================================================
%% @hidden
-spec init(port()) -> {ok, state()}.
init(Socket) ->
  PeerPort =
    case inet:peername(Socket) of
      {ok, {_Ip, Port}} -> Port;
      Error -> Error
    end,
  Authenticated = false =:= edis_config:get(requirepass),
  {ok, #state{socket = Socket, peerport = PeerPort, authenticated = Authenticated}}.

%% @hidden
-spec handle_call(X, reference(), state()) -> {stop, {unexpected_request, X}, {unexpected_request, X}, state()}.
handle_call(X, _From, State) -> {stop, {unexpected_request, X}, {unexpected_request, X}, State}.

%% @hidden
-spec handle_cast(stop | {err, binary()} | {run, binary(), [binary()]}, state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
handle_cast(stop, State) ->
  {stop, normal, State};
handle_cast({err, Message}, State) ->
  tcp_err(Message, State);
%% -- Connection -----------------------------------------------------------------------------------
handle_cast({run, <<"QUIT">>, []}, State) ->
  case tcp_ok(State) of
    {noreply, NewState} ->
      {stop, normal, NewState};
    Error ->
      Error
  end;
handle_cast({run, <<"QUIT">>, _}, State) ->
  tcp_err("wrong number of arguments for 'QUIT' command", State);
handle_cast({run, <<"AUTH">>, [Password]}, State) ->
  case edis_config:get(requirepass) of
    false ->
      tcp_ok(State);
    Password ->
      tcp_ok(State#state{authenticated = true});
    _ ->
      tcp_err(<<"invalid password">>, State#state{authenticated = false})
  end;
handle_cast({run, <<"AUTH">>, _}, State) ->
  tcp_err("wrong number of arguments for 'AUTH' command", State);
handle_cast({run, _, _}, State = #state{authenticated = false}) ->
  tcp_err("operation not permitted", State);
handle_cast({run, <<"SELECT">>, [Index]}, State) ->
  try {list_to_integer(binary_to_list(Index)), edis_config:get(databases)} of
    {Db, Dbs} when Db < 0 orelse Db >= Dbs ->
      tcp_err("invalid DB index", State);
    {Db, _} ->
      tcp_ok(State#state{db = edis_db:process(Db)})
  catch
    error:badarg ->
      ?WARN("Switching to db 0 because we received '~s' as the db index. This behaviour was copied from redis-server~n", [Index]),
      tcp_ok(State#state{db = edis_db:process(0)})
  end;
handle_cast({run, <<"SELECT">>, _}, State) ->
  tcp_err("wrong number of arguments for 'SELECT' command", State);
handle_cast({run, <<"PING">>, []}, State) ->
  try edis_db:ping(State#state.db) of
    pong -> tcp_ok(<<"PONG">>, State)
  catch
    _:Error ->
      ?WARN("Error pinging db #~p: ~p~n", [Error]),
      tcp_err(<<"database is down">>, State)
  end;
handle_cast({run, <<"PING">>, _}, State) ->
  tcp_err("wrong number of arguments for 'PING' command", State);
handle_cast({run, <<"ECHO">>, [Word]}, State) ->
  tcp_bulk(Word, State);
handle_cast({run, <<"ECHO">>, _}, State) ->
  tcp_err("wrong number of arguments for 'ECHO' command", State);

%% -- Server ---------------------------------------------------------------------------------------
handle_cast({run, <<"MONITOR">>, []}, State) ->
  ok = edis_db_monitor:add_sup_handler(),
  tcp_ok(State);
handle_cast({run, <<"MONITOR">>, _}, State) ->
  tcp_err("wrong number of arguments for 'MONITOR' command", State);
handle_cast({run, <<"SAVE">>, []}, State) ->
  try edis_db:save(State#state.db) of
    ok -> tcp_ok(State)
  catch
    _:Error ->
      ?WARN("Error saving db #~p: ~p~n", [Error]),
      tcp_err(<<"database is down">>, State)
  end;
handle_cast({run, <<"SAVE">>, _}, State) ->
  tcp_err("wrong number of arguments for 'SAVE' command", State);
handle_cast({run, <<"SHUTDOWN">>, []}, State) ->
  _ = spawn(edis, stop, []),
  {stop, normal, State};
handle_cast({run, <<"SHUTDOWN">>, _}, State) ->
  tcp_err("wrong number of arguments for 'SHUTDOWN' command", State);
handle_cast({run, Command, Args}, State)
  when Command == <<"SYNC">> orelse Command == <<"SLOWLOG">>
  orelse Command == <<"SLAVEOF">> ->
  ?WARN("Unsupported command: ~s~p~n", [Command, Args]),
  tcp_err("unsupported command", State);

%% -- Errors ---------------------------------------------------------------------------------------
handle_cast({run, Command, _Args}, State) ->
  tcp_err(["unknown command '", Command, "'"], State).

%% @hidden
-spec handle_info(term(), state()) -> {noreply, state(), hibernate}.
handle_info(#edis_command{db = 0} = Command, State) ->
  tcp_ok(io_lib:format("~p ~p ~p", [Command#edis_command.timestamp,
                                    Command#edis_command.cmd,
                                    Command#edis_command.args]), State);
handle_info(#edis_command{} = Command, State) ->
  tcp_ok(io_lib:format("~p (db ~p) ~p ~p", [Command#edis_command.timestamp,
                                            Command#edis_command.db,
                                            Command#edis_command.cmd,
                                            Command#edis_command.args]), State);
handle_info({gen_event_EXIT, _Handler, Reason}, State) ->
  ?INFO("Monitor deactivated. Reason: ~p~n", [Reason]),
  {noreply, State, hibernate};
handle_info(_, State) -> {noreply, State, hibernate}.

%% @hidden
-spec terminate(term(), state()) -> ok.
terminate(_, _) -> ok.

%% @hidden
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% ====================================================================
%% Internal functions
%% ====================================================================
%% @private
-spec tcp_bulk(iodata(), state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
tcp_bulk(Message, State) ->
  case tcp_send(["$", integer_to_list(iolist_size(Message))], State) of
    {noreply, NewState} -> tcp_send(Message, NewState);
    Error -> Error
  end.

%% @private
-spec tcp_err(binary(), state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
tcp_err(Message, State) ->
  tcp_send(["-ERR ", Message], State).

%% @private
-spec tcp_ok(state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
tcp_ok(State) ->
  tcp_ok("OK", State).
%% @private
-spec tcp_ok(binary(), state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
tcp_ok(Message, State) ->
  tcp_send(["+", Message], State).


%% @private
-spec tcp_send(iodata(), state()) -> {noreply, state()} | {stop, normal | {error, term()}, state()}.
tcp_send(Message, State) ->
  ?CDEBUG(data, "~p << ~s~n", [State#state.peerport, Message]),
  try gen_tcp:send(State#state.socket, [Message, "\r\n"]) of
    ok ->
      {noreply, State};
    {error, closed} ->
      ?DEBUG("Connection closed~n", []),
      {stop, normal, State};
    {error, Error} ->
      ?THROW("Couldn't send msg through TCP~n\tError: ~p~n", [Error]),
      {stop, {error, Error}, State}
  catch
    _:{Exception, _} ->
      ?THROW("Couldn't send msg through TCP~n\tError: ~p~n", [Exception]),
      {stop, normal, State};
    _:Exception ->
      ?THROW("Couldn't send msg through TCP~n\tError: ~p~n", [Exception]),
      {stop, normal, State}
  end.