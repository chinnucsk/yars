-module(yeref).

%-export([]).
-compile([export_all]).

-include("yaws.hrl").

start(SConf) ->
    RequestPoolSize = list_to_integer(proplists:get_value("request_pool_size", SConf#sconf.opaque, 10)),
    SlowRequestPoolSize = list_to_integer(proplists:get_value("slow_request_pool_size", SConf#sconf.opaque, 10)),

    %%Get the rack application location
    AppRoot = case lists:reverse(SConf#sconf.docroot) of
        "cilbup/" ++ Rest ->
            lists:reverse(Rest);
        _ ->
            SConf#sconf.docroot
    end,

    %%Start rack application instances 
    spawn(fun() ->
      register(rack_instance, self()),
      process_flag(trap_exit, true),
      Cmd = lists:flatten(io_lib:format("bundle exec \"ruby ./ruby/src/rack_instance.rb -r ~s\"", [AppRoot])),
      Port = open_port({spawn, Cmd}, [{packet, 4}, nouse_stdio, exit_status, binary]),
      port_loop(Port, 10000, "cmd")
    end),

    ok.

wrap(Command) ->
 spawn(fun() -> process_flag(trap_exit, true), Port = create_port(Command), port_loop(Port, infinity, Command) end).
wrap(Command, Timeout) -> 
  spawn(fun() -> process_flag(trap_exit, true), Port = create_port(Command), port_loop(Port, Timeout, Command) end).

create_port(Command) ->
  open_port({spawn, Command}, [{packet, 4}, nouse_stdio, exit_status, binary]).

port_loop(Port, Timeout, Command) ->
  receive
    noose -> 
      io:format("noose~n"),
      port_close(Port),
      noose;
    shutdown ->
      io:format("shutdown~n"),
      port_close(Port),
      exit(shutdown);
    {Source, host} -> 
      io:format("host~n"),
      Source ! {Port, node()},
      port_loop(Port,Timeout,Command);
    {Source, heat} -> 
      io:format("heat~n"),
      Port ! {self(), {command, term_to_binary(ping)}},
      Hot = term_to_binary(pong),
      receive
        {Port, {data, Hot}} -> 
          Source ! {self(), hot}
      end,
      port_loop(Port, Timeout, Command);
    {Source, api} -> 
      io:format("api~n"),
      Port ! {self(), {command, term_to_binary(api)}},
      receive
        {Port, {data, Result}} ->   
          {result, Api} = binary_to_term(Result),
          Source ! {self(), tuple_to_list(Api)}
      end,
      port_loop(Port,Timeout,Command);
    {Source, {command, Message}} -> 
      io:format("command~n"),
      Port ! {self(), {command, Message}},
      receive
        {Port, {data, Result}} ->
          DB = binary_to_term(Result),
          case DB of
            {last_result, X} ->
              Source ! {self(), {result, X}},
              port_close(Port),
              exit(last_result);
            Z -> 
              Source ! {self(), Z}
          end
      after Timeout ->
        io:format("Timeout~n"),
        error_logger:error_msg("Port Wrapper ~p timed out in mid operation (~p)!~n", [self(),Message]),
        % We timed out, which means we need to close and then restart the port
        port_close(Port), % Should SIGPIPE the child.
        exit(timed_out)
      end,
      port_loop(Port,Timeout,Command);
    {_Source, {just_send_a_command, Message}} -> 
      io:format("just~n"),
      Port ! {self(), {command, Message}},
      port_loop(Port,Timeout,Command);
    {Port, {exit_status, Code}} ->
      io:format("exit status ~p~n",[Code]),
      % Hard and Unanticipated Crash
      error_logger:error_msg( "Port closed! ~p~n", [Port] ),
      exit({error, Code});
    {'EXIT',_Pid,shutdown} ->
      io:format("EXIT~n"),
      port_close(Port),
      exit(shutdown);
    Any -> 
      error_logger:warning_msg("PortWrapper ~p got unexpected message: ~p~n", [self(), Any]),
      port_loop(Port, Timeout, Command)
  end.
    

