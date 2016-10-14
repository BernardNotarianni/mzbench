-module(mzb_api_auth).

-behaviour(gen_server).

%% API
-export([
    start_link/0,
    auth_connection/3,
    auth_connection_by_ref/2,
    sign_out_connection/1,
    auth_api_call/3,
    generate_token/2
]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-record(s, {start_id = undefined :: string()}).

-define(REF_SIZE, 32).
-define(DEFAULT_EXPIRATION_TIME_S, 259200). % 3 days
-define(VALIDATE_TOKENS_TIMEOUT_MS, 5000).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

auth_connection(ConnectionPid, "anonymous", _) ->
    case get_methods() of
        [] ->
            UserInfo =
                #{
                    login => "anonymous",
                    login_type => "undefined",
                    name => "anonymous",
                    picture_url => "",
                    email => ""
                },
            Ref = add_connection(ConnectionPid, UserInfo),
            {ok, Ref, UserInfo};
        List when is_list(List) ->
            AuthTypes = [{Type, mzb_bc:maps_get(client_id, Opts, undefined)} || {Type, Opts} <- List],
            {error, {forbidden, {use, maps:from_list(AuthTypes)}}}
    end;

auth_connection(ConnectionPid, "google" = Type, Code) ->
    try
        Tokens = google_tokens(Code, get_opts(Type)),
        IdToken = maps:get(<<"id_token">>, Tokens),
        Info = google_token_info("id_token", IdToken, get_opts(Type)),
        case maps:find(<<"email">>, Info) of
            {ok, Email} ->
                Name = mzb_bc:maps_get(<<"name">>, Info, ""),
                Picture = mzb_bc:maps_get(<<"picture">>, Info, ""),
                UserInfo =
                    #{
                        login => binary_to_list(Email),
                        login_type => Type,
                        name => binary_to_list(Name),
                        picture_url => binary_to_list(Picture),
                        email => binary_to_list(Email)
                    },
                Ref = add_connection(ConnectionPid, UserInfo),
                {ok, Ref, UserInfo};
            error -> {error, "no_user_email"}
        end
    catch
        {google_api, Method, Error} ->
            {error, mzb_string:format("Google ~p return error ~p", [Method, Error])}
    end.

auth_connection_by_ref(ConnectionPid, Ref) ->
    gen_server:call(?MODULE, {auth_connection_by_ref, ConnectionPid, Ref}).

auth_api_call(_Method, _Path, Ref) ->
    case get_methods() of
        [] -> "anonymous";
        _ ->
            case get_user_info(Ref) of
                {ok, UserInfo} -> maps:get(login, UserInfo);
                {error, unknown_ref} -> erlang:error(forbidden)
            end
    end.

sign_out_connection(Ref) ->
    gen_server:call(?MODULE, {remove_connection, Ref}).

add_connection(ConnectionPid, UserInfo) ->
    Ref = generate_ref(),
    ok = gen_server:call(?MODULE, {add_connection, ConnectionPid, Ref, UserInfo}),
    Ref.

generate_token(Lifetime, Ref) ->
    case gen_server:call(?MODULE, {generate_token, Lifetime, Ref}) of
        {ok, Token} -> Token;
        {error, Reason} -> erlang:error(Reason)
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    DetsFile = filename:join(mzb_api_server:server_data_dir(), ".tokens.dets"),
    {ok, _} = dets:open_file(auth_tokens, [{file, DetsFile}, {type, set}]),
    erlang:send_after(?VALIDATE_TOKENS_TIMEOUT_MS, self(), validate),
    {ok, #s{start_id = generate_ref()}}.

handle_call({add_connection, ConnectionPid, Ref, UserInfo}, _From, State = #s{start_id = StartId}) ->
    insert(ConnectionPid, Ref, UserInfo, StartId),
    {reply, ok, State};

handle_call({auth_connection_by_ref, ConnectionPid, Ref}, _From, State = #s{start_id = StartId}) ->
    case get_user_info(Ref) of
        {ok, UserInfo} ->
            insert(ConnectionPid, Ref, UserInfo, StartId),
            {reply, {ok, UserInfo}, State};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({remove_connection, Ref}, _From, State) ->
    dets:delete(auth_tokens, Ref),
    {reply, ok, State};

handle_call({generate_token, Lifetime, Ref}, _From, State = #s{start_id = StartId}) ->
    case get_user_info(Ref) of
        {ok, UserInfo} ->
            Token = generate_ref(),
            insert(cli, Token, UserInfo, StartId, Lifetime),
            {reply, {ok, Token}, State};
        {error, unknown_ref} ->
            {reply, {error, forbidden}, State}
    end;

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(validate, State = #s{start_id = StartId}) ->
    CurrentTime = mzb_api_bench:seconds(),
    ExpiredRefs = dets:foldl(
        fun ({Ref, #{expiratioin_ts:= Expiration}}, Acc) when CurrentTime > Expiration -> [Ref|Acc];
            ({_, _}, Acc) -> Acc
        end, [], auth_tokens),
    [remove(Ref, StartId) || Ref <- ExpiredRefs],
    erlang:send_after(?VALIDATE_TOKENS_TIMEOUT_MS, self(), validate),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_user_info(Ref) ->
    case dets:lookup(auth_tokens, Ref) of
        [{_, #{user_info:= UserInfo}}] -> {ok, UserInfo};
        [] -> {error, unknown_ref}
    end.

remove(Ref, StartId) ->
    case dets:lookup(auth_tokens, Ref) of
        [] -> ok;
        [{_, #{connection_pid:= Pid, incarnation_id:= Id}}] ->
            (Id == StartId) andalso mzb_api_ws_handler:reauth(Pid),
            dets:delete(auth_tokens, Ref)
    end.

insert(ConnectionPid, Ref, UserInfo, StartId) ->
    insert(ConnectionPid, Ref, UserInfo, StartId, ?DEFAULT_EXPIRATION_TIME_S).
insert(ConnectionPid, Ref, UserInfo, StartId, Lifetime) ->
    CreationTS = mzb_api_bench:seconds(),
    ExpirationTS = CreationTS + Lifetime,
    remove(Ref, StartId),
    dets:insert(auth_tokens, {Ref, #{user_info => UserInfo,
                                     connection_pid => ConnectionPid,
                                     creation_ts => CreationTS,
                                     expiratioin_ts => ExpirationTS,
                                     incarnation_id => StartId}}).

generate_ref() ->
    base64:encode(crypto:rand_bytes(?REF_SIZE)).

google_tokens(Code, Opts) ->
    URL = "https://www.googleapis.com/oauth2/v4/token",
    ClientID = maps:get(client_id, Opts),
    ClientSecret = maps:get(client_secret, Opts),
    RedirectURL = maps:get(redirect_url, Opts),
    Data = "code=" ++ edoc_lib:escape_uri(binary_to_list(Code)) ++
           "&client_id=" ++ edoc_lib:escape_uri(ClientID) ++
           "&client_secret=" ++ edoc_lib:escape_uri(ClientSecret) ++
           "&redirect_uri=" ++ edoc_lib:escape_uri(RedirectURL) ++
           "&grant_type=authorization_code",
    case httpc:request(post, {URL, [], "application/x-www-form-urlencoded", Data}, [], []) of
        {ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}}->
            Reply = jiffy:decode(Body, [return_maps]),
            Reply;
        {ok, {{_Version, ErrorCode, _ReasonPhrase}, _Headers, Body}}->
            erlang:error({google_api, tokens, {ErrorCode, Body}});
        {error,Error}->
            erlang:error({google_api, tokens, Error})
    end.

google_token_info(Type, Token, _Opts) ->
    URL = "https://www.googleapis.com/oauth2/v3/tokeninfo",
    Data = mzb_string:format("~s=~s", [Type, Token]),
    case httpc:request(post, {URL, [], "application/x-www-form-urlencoded", Data}, [], []) of
        {ok, {{_Version, 200, _ReasonPhrase}, _Headers, Body}}->
            Reply = jiffy:decode(Body, [return_maps]),
            Reply;
        {ok, {{_Version, ErrorCode, _ReasonPhrase}, _Headers, Body}}->
            erlang:error({google_api, token_info, {ErrorCode, Body}});
        {error,Error}->
            erlang:error({google_api, token_info, Error})
    end.

get_methods() ->
    List = application:get_env(mzbench_api, user_authentication, []),
    [{Type, maps:from_list(Opts)} || {Type, Opts} <- List].

get_opts(Type) ->
    case proplists:get_value(Type, get_methods(), undefined) of
        undefined -> erlang:error({unknown_auth_method, Type});
        Opts -> Opts
    end.
