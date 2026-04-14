%%%-------------------------------------------------------------------
%% @doc Personal domain registry: DETS persistence + registration
%% @end
%%%-------------------------------------------------------------------

-module(pm_registry).

-behaviour(gen_server).

-export([start_link/0, register/2, register/3, revoke/1, set_active/2, set_expires/2,
         list/0, size/0, refresh_fronts/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(APP, personal_mtproxy).
-define(DETS_TABLE, pm_subdomains).
-define(EXPIRY_CHECK_INTERVAL, 60000). %% check every 60 seconds

-record(state, {dets_ref, front_nodes :: [node()]}).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% Register a new personal subdomain under BaseDomain.
register(Email, BaseDomain) ->
    gen_server:call(?SERVER, {register, Email, BaseDomain, 0}).

register(Email, BaseDomain, ExpiresAt) ->
    gen_server:call(?SERVER, {register, Email, BaseDomain, ExpiresAt}).

revoke(Subdomain) ->
    gen_server:call(?SERVER, {revoke, Subdomain}).

set_active(Subdomain, Active) ->
    gen_server:call(?SERVER, {set_active, Subdomain, Active}).

set_expires(Subdomain, ExpiresAt) ->
    gen_server:call(?SERVER, {set_expires, Subdomain, ExpiresAt}).

list() ->
    gen_server:call(?SERVER, list).

size() ->
    case dets:info(?DETS_TABLE, size) of
        undefined -> 0;
        N         -> N
    end.

%% Re-scan all connected nodes, update the front_nodes cache, and replay
%% the full policy table into any newly discovered front nodes.
refresh_fronts() ->
    gen_server:call(?SERVER, refresh_fronts).

init([]) ->
    {ok, DetsFile} = application:get_env(?APP, dets_file),
    {ok, DetsRef} = dets:open_file(?DETS_TABLE, [{file, DetsFile}, {keypos, 1}]),

    %% Migrate old 3-field records {Sub, Email, Ts} -> {Sub, Email, Ts, 0, true}
    migrate(DetsRef),

    %% Monitor nodes for split-mode setup
    ok = net_kernel:monitor_nodes(true),

    FrontNodes = lists:filter(fun is_front_node/1, [node() | nodes()]),

    Now = erlang:system_time(second),
    ok = dets:foldl(
      fun({Subdomain, _Email, _Ts, ExpiresAt, Active}, ok) ->
              Expired = ExpiresAt > 0 andalso ExpiresAt < Now,
              if Active andalso not Expired ->
                  broadcast_policy(add, Subdomain, FrontNodes);
                 true -> ok
              end;
         ({_Subdomain, _Email, _Ts}, ok) ->
              ok
      end,
      ok, DetsRef),

    erlang:send_after(?EXPIRY_CHECK_INTERVAL, self(), check_expiry),

    {ok, #state{dets_ref = DetsRef, front_nodes = FrontNodes}}.

handle_call({register, Email, BaseDomain, ExpiresAt}, _From, State = #state{dets_ref = DetsRef}) ->
    case generate_slug(DetsRef, BaseDomain, 5) of
        {error, Reason} ->
            pm_prometheus:count_inc(personal_mtproxy_registration_total, 1, [error]),
            {reply, {error, Reason}, State};
        Subdomain ->
            {ok, [#{port := Port, secret := BaseSecret} | _]} = application:get_env(mtproto_proxy, ports),
            ok = dets:insert(DetsRef, {Subdomain, Email, erlang:system_time(second), ExpiresAt, true}),
            ok = broadcast_policy(add, Subdomain, State#state.front_nodes),
            pm_prometheus:count_inc(personal_mtproxy_registration_total, 1, [ok]),
            {reply, {ok, Subdomain, Port, BaseSecret}, State}
    end;

handle_call({revoke, Subdomain}, _From, State = #state{dets_ref = DetsRef}) ->
    case dets:lookup(DetsRef, Subdomain) of
        [] ->
            pm_prometheus:count_inc(personal_mtproxy_revocation_total, 1, [not_found]),
            {reply, {error, not_found}, State};
        _ ->
            ok = dets:delete(DetsRef, Subdomain),
            ok = broadcast_policy(del, Subdomain, State#state.front_nodes),
            pm_prometheus:count_inc(personal_mtproxy_revocation_total, 1, [ok]),
            {reply, ok, State}
    end;

handle_call({set_active, Subdomain, Active}, _From, State = #state{dets_ref = DetsRef}) ->
    case dets:lookup(DetsRef, Subdomain) of
        [] ->
            {reply, {error, not_found}, State};
        [{Subdomain, Email, Ts, ExpiresAt, _OldActive}] ->
            ok = dets:insert(DetsRef, {Subdomain, Email, Ts, ExpiresAt, Active}),
            case Active of
                true  -> broadcast_policy(add, Subdomain, State#state.front_nodes);
                false -> broadcast_policy(del, Subdomain, State#state.front_nodes)
            end,
            {reply, ok, State}
    end;

handle_call({set_expires, Subdomain, ExpiresAt}, _From, State = #state{dets_ref = DetsRef}) ->
    case dets:lookup(DetsRef, Subdomain) of
        [] ->
            {reply, {error, not_found}, State};
        [{Subdomain, Email, Ts, _OldExpires, Active}] ->
            ok = dets:insert(DetsRef, {Subdomain, Email, Ts, ExpiresAt, Active}),
            {reply, ok, State}
    end;

handle_call(list, _From, State = #state{dets_ref = DetsRef}) ->
    Entries = dets:match_object(DetsRef, {'_', '_', '_', '_', '_'}),
    {reply, Entries, State};

handle_call(refresh_fronts, _From, State = #state{dets_ref = DetsRef, front_nodes = OldFronts}) ->
    NewFronts = lists:filter(fun is_front_node/1, [node() | nodes()]),
    Added = NewFronts -- OldFronts,
    replay_to_nodes(Added, DetsRef),
    ?LOG_INFO("refresh_fronts: old=~p new=~p added=~p", [OldFronts, NewFronts, Added]),
    {reply, {ok, NewFronts}, State#state{front_nodes = NewFronts}}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({nodeup, Node}, State = #state{dets_ref = DetsRef, front_nodes = FrontNodes}) ->
    case is_front_node(Node) of
        true ->
            replay_to_nodes([Node], DetsRef),
            {noreply, State#state{front_nodes = [Node | FrontNodes]}};
        false ->
            {noreply, State}
    end;

handle_info({nodedown, Node}, State = #state{front_nodes = FrontNodes}) ->
    {noreply, State#state{front_nodes = lists:delete(Node, FrontNodes)}};

handle_info(check_expiry, State = #state{dets_ref = DetsRef}) ->
    Now = erlang:system_time(second),
    dets:foldl(
      fun({Subdomain, Email, Ts, ExpiresAt, true}, ok) when ExpiresAt > 0 andalso ExpiresAt < Now ->
              ?LOG_INFO("Proxy expired, deactivating: ~s", [Subdomain]),
              dets:insert(DetsRef, {Subdomain, Email, Ts, ExpiresAt, false}),
              broadcast_policy(del, Subdomain, State#state.front_nodes),
              ok;
         (_, ok) -> ok
      end,
      ok, DetsRef),
    erlang:send_after(?EXPIRY_CHECK_INTERVAL, self(), check_expiry),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, #state{dets_ref = DetsRef}) ->
    ok = dets:close(DetsRef),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Private helpers

migrate(DetsRef) ->
    OldEntries = dets:match_object(DetsRef, {'_', '_', '_'}),
    lists:foreach(
      fun({Subdomain, Email, Ts}) ->
              ?LOG_INFO("Migrating record: ~s", [Subdomain]),
              dets:insert(DetsRef, {Subdomain, Email, Ts, 0, true});
         (_) -> ok
      end,
      OldEntries).

replay_to_nodes(Nodes, DetsRef) ->
    Now = erlang:system_time(second),
    dets:foldl(
      fun({Subdomain, _Email, _Ts, ExpiresAt, Active}, ok) ->
              Expired = ExpiresAt > 0 andalso ExpiresAt < Now,
              if Active andalso not Expired ->
                  [policy_rpc(Node, add, Subdomain) || Node <- Nodes];
                 true -> ok
              end,
              ok;
         ({_Subdomain, _Email, _Ts}, ok) ->
              ok
      end,
      ok, DetsRef).

broadcast_policy(Op, Subdomain, FrontNodes) ->
    [policy_rpc(Node, Op, Subdomain) || Node <- FrontNodes],
    ok.

policy_rpc(Node, Op, Subdomain) ->
    try erpc:call(Node, mtp_policy_table, Op, [personal_domains, tls_domain, Subdomain]) of
        ok -> ok
    catch Class:Reason ->
        ?LOG_WARNING("mtp_policy_table:~p(~p) on ~p failed: ~p:~p",
                     [Op, Subdomain, Node, Class, Reason])
    end.

is_front_node(Node) ->
    try erpc:call(Node, erlang, whereis, [mtp_policy_table]) of
        Pid when is_pid(Pid) -> true;
        undefined            -> false
    catch _:_ -> false
    end.

generate_slug(DetsRef, BaseDomain, Retries) ->
    case Retries of
        0 ->
            {error, max_retries};
        _ ->
            Slug = [($a + rand:uniform(26) - 1) || _ <- lists:seq(1, 5)],
            Subdomain = list_to_binary(Slug ++ "." ++ BaseDomain),
            case dets:lookup(DetsRef, Subdomain) of
                [] ->
                    Subdomain;
                _ ->
                    pm_prometheus:count_inc(personal_mtproxy_slug_collision_total, 1, []),
                    generate_slug(DetsRef, BaseDomain, Retries - 1)
            end
    end.
