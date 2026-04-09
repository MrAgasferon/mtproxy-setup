%%%-------------------------------------------------------------------
%% @doc personal_mtproxy application start handler
%% @end
%%%-------------------------------------------------------------------

-module(personal_mtproxy_app).

-behaviour(application).

-export([start/2, stop/1]).

-include_lib("kernel/include/logger.hrl").

-define(APP, personal_mtproxy).

start(_StartType, _StartArgs) ->
    case validate_mtproto_ports() of
        ok ->
            Res = {ok, _} = personal_mtproxy_sup:start_link(),

            {CowboyIp, CowboyPort, Kind} = cowboy_listen_addr(),

            {ok, BaseDomain} = application:get_env(?APP, base_domain),
            {ok, SslCert} = application:get_env(?APP, ssl_cert),
            {ok, SslKey} = application:get_env(?APP, ssl_key),

            {ok, DetsFile} = application:get_env(?APP, dets_file),
            ok = filelib:ensure_dir(DetsFile),

            code:load_file(pm_auth_middleware),
            cowboy:start_tls(
              https_listener,
              [{port, CowboyPort}, {ip, CowboyIp},
               {certfile, SslCert}, {keyfile, SslKey}],
              #{env => #{dispatch => routes()},
                middlewares => [cowboy_router, pm_auth_middleware, cowboy_handler]}
            ),

            ?LOG_INFO("Personal MTProto Proxy UI on https://~s:~p", [inet:ntoa(CowboyIp), CowboyPort]),

            case Kind of
                fronting ->
                    {ok, [#{port := ProxyPort} | _]} = application:get_env(mtproto_proxy, ports),
                    ?LOG_INFO("To open UI via domain fronting, use https://~s:~p",
                              [BaseDomain, ProxyPort]),
                    ok = mtp_policy_table:add(personal_domains, tls_domain,
                                              list_to_binary(BaseDomain));
                explicit ->
                    ok
            end,

            Res;
        {error, Reason} ->
            ?LOG_ERROR("mtproto_proxy port validation failed: ~p", [Reason]),
            {error, Reason}
    end.

stop(_State) ->
    ok.

validate_mtproto_ports() ->
    case application:get_env(mtproto_proxy, ports) of
        undefined ->
            {error, no_ports_configured};
        {ok, []} ->
            {error, no_ports_configured};
        {ok, [#{port := Port, secret := Secret} | Rest]} ->
            case lists:all(
              fun(#{port := P, secret := S}) ->
                      P == Port andalso S == Secret
              end,
              Rest)
            of
                true ->
                    ok;
                false ->
                    {error, {mismatched_ports, [#{port => Port, secret => Secret} | Rest]}}
            end;
        _ ->
            {error, invalid_port_config}
    end.

cowboy_listen_addr() ->
    case {application:get_env(?APP, web_listen_ip), application:get_env(?APP, web_listen_port)} of
        {{ok, Ip}, {ok, Port}} ->
            {ok, ParsedIp} = inet:parse_address(Ip),
            {ParsedIp, Port, explicit};
        _ ->
            {ok, DomainFronting} = application:get_env(mtproto_proxy, domain_fronting),
            case string:split(DomainFronting, ":") of
                [Host, PortStr] ->
                    {ok, Ip} = inet:parse_address(Host),
                    {Ip, list_to_integer(PortStr), fronting};
                _ ->
                    error({badarg, invalid_domain_fronting_config, DomainFronting})
            end
    end.

routes() ->
    Dispatch = cowboy_router:compile([
        {'_', [
            {"/api/proxies",     pm_web_handler, []},
            {"/api/config",      pm_web_handler, []},
            {"/api/connections", pm_web_handler, []},
            {"/",                cowboy_static, {priv_file, personal_mtproxy, "htdocs/index.html"}},
            {"/admin.html",      cowboy_static, {priv_file, personal_mtproxy, "htdocs/admin.html"}},
            {"/static/[...]",    cowboy_static, {priv_dir,  personal_mtproxy, "htdocs"}}
        ]}
    ]),
    Dispatch.
