%%%-------------------------------------------------------------------
%%% -*- coding: utf-8 -*-
%%% @author Timofey Barmin
%%% @copyright (C) 2015, Eltex, Novosibirsk, Russia
%%% @doc
%%%
%%% @end
%%% Software distributed under the License is distributed on an "AS IS"
%%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%%% the License for the specific language governing rights and limitations
%%% under the License.
%%% Current module based on disk_log distributed by Ericsson AB
%%%-------------------------------------------------------------------

-module(chronica_disk_log).

-export([
    accessible_logs/0,
    alog/2,
    alog_terms/2,
    balog/2,
    balog_terms/2,
    bchunk/2,
    bchunk/3,
    block/1,
    block/2,
    blog/2,
    blog_terms/2,
    breopen/3,
    btruncate/2,
    change_header/2,
    change_notify/3,
    change_size/2,
    chunk/2,
    chunk/3,
    chunk_info/1,
    chunk_step/3,
    close/1,
    format_error/1,
    inc_wrap_file/1,
    info/1,
    istart_link/1,
    lclose/1,
    lclose/2,
    log/2,
    log_terms/2,
    open/1,
    reopen/2,
    reopen/3,
    start/0,
    sync/1,
    truncate/1,
    truncate/2,
    unblock/1
    ]).

%% Internal exports
-export([
    init/2,
    internal_open/2,
    system_continue/3,
    system_terminate/4,
    system_code_change/4
    ]).

%% To be used by chronica_disk_log_h.erl (not (yet) in Erlang/OTP) only.
-export([ll_open/1, ll_close/1, do_log/2, do_sync/1, do_info/2]).

%% To be used by wrap_log_reader only.
-export([ichunk_end/2]).

%% To be used for debugging only:
-export([pid2name/1]).

-type dlog_state_error() :: 'ok' | {'error', _}.

-record(state, {
    queue = [],
    messages = [],
    parent,
    server,
    cnt = 0           :: non_neg_integer(),
    args,
    error_status = ok :: dlog_state_error(),
    cache_error = ok     %% cache write error after timeout
    }).

-include("chronica_disk_log.hrl").

-define(failure(Error, Function, Arg), {{failed, Error}, [{?MODULE, Function, Arg}]}).

-define(PROFILE(C), void).

-compile(inline_list_funcs).
-compile(inline).
-compile({inline, [
    {log_loop, 4},
    {log_end_sync, 2},
    {replies, 2},
    {rflat, 1},
    {check_bytes, 1}
    ]}).

%%%----------------------------------------------------------------------
%%% Contract type specifications
%%%----------------------------------------------------------------------

-type bytes()          :: binary() | [byte()].

-type log()            :: term().  % XXX: refine
-type file_error()     :: term().  % XXX: refine
-type filename()       :: string().
-type invalid_header() :: term().  % XXX: refine

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%%-----------------------------------------------------------------
%% This module implements the API, and the processes for each log.
%% There is one process per log.
%%-----------------------------------------------------------------

-type open_error_rsn() :: 'no_such_log'
                        | {'badarg', term()}
                        | {'size_mismatch', dlog_size(), dlog_size()}
                        | {'arg_mismatch', dlog_optattr(), term(), term()}
                        | {'name_already_open', log()}
                        | {'open_read_write', log()}
                        | {'open_read_only', log()}
                        | {'need_repair', log()}
                        | {'not_a_log_file', string()}
                        | {'invalid_index_file', string()}
                        | {'invalid_header', invalid_header()}
                        | {'file_error', filename(), file_error()}
                        | {'node_already_open', log()}.
-type dist_error_rsn() :: 'nodedown' | open_error_rsn().
-type ret()            :: {'ok', log()}
                        | {'repaired', log(), {'recovered', non_neg_integer()},
                           {'badbytes', non_neg_integer()}}.
-type open_ret()       :: ret() | {'error', open_error_rsn()}.
-type dist_open_ret()  :: {[{node(), ret()}],
                           [{node(), {'error', dist_error_rsn()}}]}.
-type all_open_ret()   :: open_ret() | dist_open_ret().

-spec open(Args :: dlog_options()) -> all_open_ret().
open(A) ->
    chronica_disk_log_server:open(check_arg(A, #arg{options = A})).

-type log_error_rsn() :: 'no_such_log' | 'nonode' | {'read_only_mode', log()}
                       | {'format_external', log()} | {'blocked_log', log()}
                       | {'full', log()} | {'invalid_header', invalid_header()}
                       | {'file_error', filename(), file_error()}.

-spec log(Log :: any(), Term :: term()) -> 'ok' | {'error', log_error_rsn()}.
log(Log, Term) ->
    req(Log, {log, erlang:term_to_binary(Term)}).

-spec blog(Log :: any(), Bytes :: bytes()) -> 'ok' | {'error', log_error_rsn()}.
blog(Log, Bytes) ->
    req(Log, {blog, check_bytes(Bytes)}).

-spec log_terms(Log :: any(), Terms :: [any()]) -> 'ok' | {'error', any()}.
log_terms(Log, Terms) ->
    Bs = terms2bins(Terms),
    req(Log, {log, Bs}).

-spec blog_terms(Log :: any(), Bytes :: [bytes()]) -> 'ok' | {'error', any()}.
blog_terms(Log, Bytess) ->
    Bs = check_bytes_list(Bytess),
    req(Log, {blog, Bs}).

-type notify_ret() :: 'ok' | {'error', 'no_such_log'}.

-spec alog(Log :: any(), Term :: term()) -> notify_ret().
alog(Log, Term) ->
    notify(Log, {alog, erlang:term_to_binary(Term)}).

-spec alog_terms(Log :: any(), Terms :: [term()]) -> notify_ret().
alog_terms(Log, Terms) ->
    Bs = terms2bins(Terms),
    notify(Log, {alog, Bs}).

-spec balog(Log :: any(), Bytes :: bytes()) -> notify_ret().
balog(Log, Bytes) ->
    notify(Log, {balog, check_bytes(Bytes)}).

-spec balog_terms(Log :: any(), Bytes :: [bytes()]) -> notify_ret().
balog_terms(Log, Bytess) ->
    Bs = check_bytes_list(Bytess),
    notify(Log, {balog, Bs}).

-type close_error_rsn() ::'no_such_log' | 'nonode'
                         | {'file_error', filename(), file_error()}.

-spec close(Log :: any()) -> 'ok' | {'error', close_error_rsn()}.
close(Log) ->
    req(Log, close).

-type lclose_error_rsn() :: 'no_such_log'
                          | {'file_error', filename(), file_error()}.

-spec lclose(Log :: any()) -> 'ok' | {'error', lclose_error_rsn()}.
lclose(Log) ->
    lclose(Log, erlang:node()).

-spec lclose(Log :: any(), Node :: erlang:node()) -> 'ok' | {'error', lclose_error_rsn()}.
lclose(Log, Node) ->
    lreq(Log, close, Node).

-type trunc_error_rsn() :: 'no_such_log' | 'nonode'
                         | {'read_only_mode', log()}
                         | {'blocked_log', log()}
                         | {'invalid_header', invalid_header()}
                         | {'file_error', filename(), file_error()}.

-spec truncate(Log :: any()) -> 'ok' | {'error', trunc_error_rsn()}.
truncate(Log) ->
    req(Log, {truncate, none, truncate, 1}).

-spec truncate(Log :: any(), Head :: any()) -> 'ok' | {'error', trunc_error_rsn()}.
truncate(Log, Head) ->
    req(Log, {truncate, {ok, erlang:term_to_binary(Head)}, truncate, 2}).

-spec btruncate(Log :: any(), Head :: bytes()) -> 'ok' | {'error', trunc_error_rsn()}.
btruncate(Log, Head) ->
    req(Log, {truncate, {ok, check_bytes(Head)}, btruncate, 2}).

-spec reopen(Log :: any(), Filename :: string()) -> 'ok' | {'error', any()}.
reopen(Log, NewFile) ->
    req(Log, {reopen, NewFile, none, reopen, 2}).

-spec reopen(Log :: any(), Filename :: string(), Head :: any()) ->
    'ok' | {'error', any()}.
reopen(Log, NewFile, NewHead) ->
    req(Log, {reopen, NewFile, {ok, erlang:term_to_binary(NewHead)}, reopen, 3}).

-spec breopen(Log :: any(), Filename :: string(), Head :: bytes()) ->
    'ok' | {'error', any()}.
breopen(Log, NewFile, NewHead) ->
    req(Log, {reopen, NewFile, {ok, check_bytes(NewHead)}, breopen, 3}).

-type inc_wrap_error_rsn() :: 'no_such_log' | 'nonode'
                            | {'read_only_mode', log()}
                            | {'blocked_log', log()} | {'halt_log', log()}
                            | {'invalid_header', invalid_header()}
                            | {'file_error', filename(), file_error()}.

-spec inc_wrap_file(Log :: any()) -> 'ok' | {'error', inc_wrap_error_rsn()}.
inc_wrap_file(Log) ->
    req(Log, inc_wrap_file).

-spec change_size(Log :: any(), Size :: dlog_size()) -> 'ok' | {'error', any()}.
change_size(Log, NewSize) ->
    req(Log, {change_size, NewSize}).

-spec change_notify(Log :: any(), Pid :: pid(), Notify :: boolean()) ->
    'ok' | {'error', any()}.
change_notify(Log, Pid, NewNotify) ->
    req(Log, {change_notify, Pid, NewNotify}).

-spec change_header(Log :: any(), Head :: {atom(), any()}) ->
    'ok' | {'error', any()}.
change_header(Log, NewHead) ->
    req(Log, {change_header, NewHead}).

-type sync_error_rsn() :: 'no_such_log' | 'nonode' | {'read_only_mode', log()}
                        | {'blocked_log', log()}
                        | {'file_error', filename(), file_error()}.

-spec sync(Log :: any()) -> 'ok' | {'error', sync_error_rsn()}.
sync(Log) ->
    req(Log, sync).

-type block_error_rsn() :: 'no_such_log' | 'nonode' | {'blocked_log', log()}.

-spec block(Log :: any()) -> 'ok' | {'error', block_error_rsn()}.
block(Log) ->
    block(Log, true).

-spec block(Log :: any(), QueueLogRecords :: boolean()) -> 'ok' | {'error', any()}.
block(Log, QueueLogRecords) ->
    req(Log, {block, QueueLogRecords}).

-type unblock_error_rsn() :: 'no_such_log' | 'nonode'
                           | {'not_blocked', log()}
                           | {'not_blocked_by_pid', log()}.

-spec unblock(Log :: any()) -> 'ok' | {'error', unblock_error_rsn()}.
unblock(Log) ->
    req(Log, unblock).

-spec format_error(Error :: any()) -> string().
format_error(Error) ->
    do_format_error(Error).

-spec info(Log :: any()) -> [{atom(), any()}] | {'error', any()}.
info(Log) ->
    sreq(Log, info).

-spec pid2name(Pid :: pid()) -> {'ok', log()} | 'undefined'.
pid2name(Pid) ->
    chronica_disk_log_server:start(),
    case ets:lookup(?DISK_LOG_PID_TABLE, Pid) of
        [] -> undefined;
        [{_Pid, Log}] -> {ok, Log}
    end.

%% This function Takes 3 args, a Log, a Continuation and N.
%% It retuns a {Cont2, ObjList} | eof | {error, Reason}
%% The initial continuation is the atom 'start'

-spec chunk(Log :: any(), Cont :: any()) ->
    {'error', any()} | 'eof' | {any(), [any()]} | {any(), [any()], integer()}.
chunk(Log, Cont) ->
    chunk(Log, Cont, infinity).

-spec chunk(Log :: any(), Cont :: any(), N :: pos_integer() | 'infinity') ->
    {'error', any()} | 'eof' | {any(), [any()]} | {any(), [any()], integer()}.
chunk(Log, Cont, infinity) ->
    %% There cannot be more than ?MAX_CHUNK_SIZE terms in a chunk.
    ichunk(Log, Cont, ?MAX_CHUNK_SIZE);
chunk(Log, Cont, N) when erlang:is_integer(N), N > 0 ->
    ichunk(Log, Cont, N).

ichunk(Log, start, N) ->
    R = sreq(Log, {chunk, 0, [], N}),
    ichunk_end(R, Log);
ichunk(Log, #continuation{pid = Pid, pos = Pos, b = B}, N) ->
    R = req2(Pid, {chunk, Pos, B, N}),
    ichunk_end(R, Log);
ichunk(_Log, _, _) ->
    {error, {badarg, continuation}}.

ichunk_end({#continuation{} = C, R}, Log) ->
    ichunk_end(R, read_write, Log, C, 0);
ichunk_end({#continuation{} = C, R, Bad}, Log) ->
    ichunk_end(R, read_only, Log, C, Bad);
ichunk_end(R, _Log) ->
    R.

%% Create the terms on the client's heap, not the server's.
%% The list of binaries is reversed.
ichunk_end(R, Mode, Log, C, Bad) ->
    case catch bins2terms(R, []) of
        {'EXIT', _} ->
            RR = lists:reverse(R),
            ichunk_bad_end(RR, Mode, Log, C, Bad, []);
        Ts when Bad > 0 ->
            {C, Ts, Bad};
        Ts when Bad =:= 0 ->
            {C, Ts}
    end.

bins2terms([], L) ->
    L;
bins2terms([B | Bs], L) ->
    bins2terms(Bs, [binary_to_term(B) | L]).

ichunk_bad_end([B | Bs], Mode, Log, C, Bad, A) ->
    case catch binary_to_term(B) of
        {'EXIT', _} when read_write =:= Mode ->
            InfoList = info(Log),
            {_value, {file, FileName}} = lists:keysearch(file, 1, InfoList),
            File = case C#continuation.pos of
                       Pos when erlang:is_integer(Pos) -> FileName; % halt log
                       {FileNo, _} -> add_ext(FileName, FileNo) % wrap log
                   end,
            {error, {corrupt_log_file, File}};
        {'EXIT', _} when read_only =:= Mode ->
            Reread = lists:foldl(fun(Bin, Sz) ->
                                         Sz + byte_size(Bin) + ?HEADERSZ
                                 end, 0, Bs),
            NewPos = case C#continuation.pos of
                         Pos when erlang:is_integer(Pos) -> Pos-Reread;
                         {FileNo, Pos} -> {FileNo, Pos-Reread}
                     end,
            NewBad = Bad + byte_size(B),
            {C#continuation{pos = NewPos, b = []}, lists:reverse(A), NewBad};
        T ->
            ichunk_bad_end(Bs, Mode, Log, C, Bad, [T | A])
    end.

-spec bchunk(Log :: any(), Cont :: any()) ->
    {'error', any()} | 'eof' | {any(), [binary()]} | {any(), [binary()], integer()}.
bchunk(Log, Cont) ->
    bchunk(Log, Cont, infinity).

-spec bchunk(Log :: any(), Cont :: any(), N :: 'infinity' | pos_integer()) ->
    {'error', any()} | 'eof' | {any(), [binary()]} | {any(), [binary()], integer()}.
bchunk(Log, Cont, infinity) ->
    %% There cannot be more than ?MAX_CHUNK_SIZE terms in a chunk.
    bichunk(Log, Cont, ?MAX_CHUNK_SIZE);
bchunk(Log, Cont, N) when erlang:is_integer(N), N > 0 ->
    bichunk(Log, Cont, N).

bichunk(Log, start, N) ->
    R = sreq(Log, {chunk, 0, [], N}),
    bichunk_end(R);
bichunk(_Log, #continuation{pid = Pid, pos = Pos, b = B}, N) ->
    R = req2(Pid, {chunk, Pos, B, N}),
    bichunk_end(R);
bichunk(_Log, _, _) ->
    {error, {badarg, continuation}}.

bichunk_end({#continuation{} = C, R}) ->
    {C, lists:reverse(R)};
bichunk_end({#continuation{} = C, R, Bad}) ->
    {C, lists:reverse(R), Bad};
bichunk_end(R) ->
    R.

-spec chunk_step(Log :: any(), Cont :: any(), N :: integer()) ->
    {'ok', any()} | {'error', any()}.
chunk_step(Log, Cont, N) when erlang:is_integer(N) ->
    ichunk_step(Log, Cont, N).

ichunk_step(Log, start, N) ->
    sreq(Log, {chunk_step, 0, N});
ichunk_step(_Log, #continuation{pid = Pid, pos = Pos}, N) ->
    req2(Pid, {chunk_step, Pos, N});
ichunk_step(_Log, _, _) ->
    {error, {badarg, continuation}}.

-spec chunk_info(More :: any()) ->
    [{'node', erlang:node()}, ...] | {'error', {'no_continuation', any()}}.
chunk_info(#continuation{pid = Pid}) ->
   [{node, erlang:node(Pid)}];
chunk_info(BadCont) ->
   {error, {no_continuation, BadCont}}.

-spec accessible_logs() -> {[_], [_]}.
accessible_logs() ->
    chronica_disk_log_server:accessible_logs().

istart_link(Server) ->
    {ok, proc_lib:spawn_link(chronica_disk_log, init, [self(), Server])}.

%% Only for backwards compatibility, could probably be removed.
-spec start() -> 'ok'.
start() ->
    chronica_disk_log_server:start().

internal_open(Pid, A) ->
    req2(Pid, {internal_open, A}).

%%% ll_open() and ll_close() are used by chronica_disk_log_h.erl, a module not
%%% (yet) in Erlang/OTP.

%% -spec ll_open(dlog_options()) -> {'ok', Res :: _, #log{}, Cnt :: _} | Error.
ll_open(A) ->
    case check_arg(A, #arg{options = A}) of
        {ok, L} -> do_open(L);
        Error -> Error
    end.

%% -> closed | throw(Error)
ll_close(Log) ->
    close_chronica_disk_log2(Log).

check_arg([], Res) ->
    Ret = case Res#arg.head of
              none ->
                  {ok, Res};
              _ ->
                  case check_head(Res#arg.head, Res#arg.format) of
                      {ok, Head} ->
                          {ok, Res#arg{head = Head}};
                      Error ->
                          Error
                  end
          end,

    if  %% check result
        Res#arg.name =:= 0 ->
            {error, {badarg, name}};
        Res#arg.file =:= none ->
            case catch lists:concat([Res#arg.name, ".LOG"]) of
                {'EXIT', _} -> {error, {badarg, file}};
                FName ->  check_arg([], Res#arg{file = FName})
            end;
        Res#arg.repair =:= truncate, Res#arg.mode =:= read_only ->
            {error, {badarg, repair_read_only}};
        Res#arg.type =:= halt, erlang:is_tuple(Res#arg.size) ->
            {error, {badarg, size}};
        Res#arg.type =:= wrap ->
            {OldSize, Version} =
            chronica_disk_log_1:read_size_file_version(Res#arg.file),
            check_wrap_arg(Ret, OldSize, Version);
        true ->
            Ret
    end;
check_arg([{file, F} | Tail], Res) when erlang:is_list(F) ->
    check_arg(Tail, Res#arg{file = F});
check_arg([{file, F} | Tail], Res) when erlang:is_atom(F) ->
    check_arg(Tail, Res#arg{file = F});
check_arg([{linkto, Pid} |Tail], Res) when erlang:is_pid(Pid) ->
    check_arg(Tail, Res#arg{linkto = Pid});
check_arg([{linkto, none} |Tail], Res) ->
    check_arg(Tail, Res#arg{linkto = none});
check_arg([{name, Name}|Tail], Res) ->
    check_arg(Tail, Res#arg{name = Name});
check_arg([{repair, true}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = true});
check_arg([{repair, false}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = false});
check_arg([{repair, truncate}|Tail], Res) ->
    check_arg(Tail, Res#arg{repair = truncate});
check_arg([{size, Int}|Tail], Res) when erlang:is_integer(Int), Int > 0 ->
    check_arg(Tail, Res#arg{size = Int});
check_arg([{size, infinity}|Tail], Res) ->
    check_arg(Tail, Res#arg{size = infinity});
check_arg([{size, {MaxB, MaxF}}|Tail], Res)
  when erlang:is_integer(MaxB), erlang:is_integer(MaxF),
       MaxB > 0, MaxB =< ?MAX_BYTES, MaxF > 0, MaxF < ?MAX_FILES ->
    check_arg(Tail, Res#arg{size = {MaxB, MaxF}});
check_arg([{type, wrap}|Tail], Res) ->
    check_arg(Tail, Res#arg{type = wrap});
check_arg([{type, halt}|Tail], Res) ->
    check_arg(Tail, Res#arg{type = halt});
check_arg([{format, internal}|Tail], Res) ->
    check_arg(Tail, Res#arg{format = internal});
check_arg([{format, external}|Tail], Res) ->
    check_arg(Tail, Res#arg{format = external});
check_arg([{distributed, []}|Tail], Res) ->
    check_arg(Tail, Res#arg{distributed = false});
check_arg([{distributed, Nodes}|Tail], Res) when erlang:is_list(Nodes) ->
    check_arg(Tail, Res#arg{distributed = {true, Nodes}});
check_arg([{notify, true}|Tail], Res) ->
    check_arg(Tail, Res#arg{notify = true});
check_arg([{notify, false}|Tail], Res) ->
    check_arg(Tail, Res#arg{notify = false});
check_arg([{head_func, HeadFunc}|Tail], Res)  ->
    check_arg(Tail, Res#arg{head = {head_func, HeadFunc}});
check_arg([{head, Term}|Tail], Res) ->
    check_arg(Tail, Res#arg{head = {head, Term}});
check_arg([{mode, read_only}|Tail], Res) ->
    check_arg(Tail, Res#arg{mode = read_only});
check_arg([{mode, read_write}|Tail], Res) ->
    check_arg(Tail, Res#arg{mode = read_write});
check_arg(Arg, _) ->
    {error, {badarg, Arg}}.

check_wrap_arg({ok, #arg{size=infinity}}, {0, 0}, _Version) ->
    {error, {badarg, size}};
check_wrap_arg({ok, #arg{size=infinity} = Res}, OldSize, Version) ->
    NewRes = Res#arg{size = OldSize},
    check_wrap_arg({ok, NewRes}, OldSize, Version);
check_wrap_arg({ok, Res}, {0, 0}, Version) ->
    {ok, Res#arg{version = Version}};
check_wrap_arg({ok, #arg{size=OldSize} = Res}, OldSize, Version) ->
    {ok, Res#arg{version = Version}};
check_wrap_arg({ok, #arg{repair = truncate, size = Size} = Res}, _OldSize, Version) when erlang:is_tuple(Size) ->
    {ok, Res#arg{version = Version}};
check_wrap_arg({ok, #arg{size = Size} = Res}, OldSize, _Version) when erlang:is_tuple(Size) ->
    {error, {size_mismatch, OldSize, Res#arg.size}};
check_wrap_arg({ok, _Res}, _OldSize, _Version) ->
    {error, {badarg, size}};
check_wrap_arg(Ret, _OldSize, _Version) ->
    Ret.

%%%-----------------------------------------------------------------
%%% Server functions
%%%-----------------------------------------------------------------
init(Parent, Server) ->
    ?PROFILE(ep:do()),
    process_flag(trap_exit, true),
    loop(#state{parent = Parent, server = Server}).

loop(State = #state{messages = []}) ->
    receive
        Message ->
            handle(Message, State)
    end;
loop(State) ->
    [M | Ms] = State#state.messages,
    handle(M, State#state{messages = Ms}).

handle({From, write_cache}, S) when From =:= erlang:self() ->
    case catch do_write_cache(get(log)) of
        ok ->
            loop(S);
        Error ->
            loop(S#state{cache_error = Error})
    end;
handle({From, {log, B}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok, format = internal} ->
            log_loop(S, From, [B], []);
        #log{status = ok, format=external, name = Name} ->
            reply(From, {error, {format_external, Name}}, S);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {log, B}} | S#state.queue]})
    end;
handle({From, {blog, B}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok} ->
            log_loop(S, From, [B], []);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {blog, B}} | S#state.queue]})
    end;
handle({alog, B}, S) ->
    case erlang:get(log) of
        #log{mode = read_only} ->
            notify_owners({read_only, B}),
            loop(S);
        #log{status = ok, format = internal} ->
            log_loop(S, [], [B], []);
        #log{status = ok} ->
            notify_owners({format_external, B}),
            loop(S);
        #log{status = {blocked, false}} ->
            notify_owners({blocked_log, B}),
            loop(S);
        _ ->
            loop(S#state{queue = [{alog, B} | S#state.queue]})
    end;
handle({balog, B}, S) ->
    case erlang:get(log) of
        #log{mode = read_only} ->
            notify_owners({read_only, B}),
            loop(S);
        #log{status = ok} ->
            log_loop(S, [], [B], []);
        #log{status = {blocked, false}} ->
            notify_owners({blocked_log, B}),
            loop(S);
        _ ->
            loop(S#state{queue = [{balog, B} | S#state.queue]})
    end;
handle({From, {block, QueueLogRecs}}, S) ->
    case erlang:get(log) of
        #log{status = ok} = L ->
            do_block(From, QueueLogRecs, L),
            reply(From, ok, S);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {block, QueueLogRecs}} | S#state.queue]})
    end;
handle({From, unblock}, S) ->
    case erlang:get(log) of
        #log{status = ok, name = Name} ->
            reply(From, {error, {not_blocked, Name}}, S);
        #log{blocked_by = From} = L ->
            S2 = do_unblock(L, S),
            reply(From, ok, S2);
        #log{name = Name} ->
            reply(From, {error, {not_blocked_by_pid, Name}}, S)
    end;
handle({From, sync}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok} ->
            sync_loop([From], S);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, sync} | S#state.queue]})
    end;
handle({From, {truncate, Head, F, A}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok} when S#state.cache_error =/= ok ->
            loop(cache_error(S, [From]));
        #log{status = ok, head = V} = L ->
            H = merge_head(Head, V),
            case catch do_trunc(L, H) of
                ok ->
                    erlang:erase(is_full),
                    notify_owners({truncated, S#state.cnt}),
                    N = if Head =:= none -> 0; true -> 1 end,
                    reply(From, ok, (state_ok(S))#state{cnt = N});
                Error ->
                    do_exit(S, From, Error, ?failure(Error, F, A))
            end;
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {truncate, Head, F, A}} | S#state.queue]})
    end;
handle({From, {chunk, Pos, B, N}},  S) ->
    case erlang:get(log) of
        #log{status = ok} when S#state.cache_error =/= ok ->
            loop(cache_error(S, [From]));
        #log{status = ok} = L ->
            R = do_chunk(L, Pos, B, N),
            reply(From, R, S);
        #log{blocked_by = From} = L ->
            R = do_chunk(L, Pos, B, N),
            reply(From, R, S);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _L ->
            loop(S#state{queue = [{From, {chunk, Pos, B, N}} | S#state.queue]})
    end;
handle({From, {chunk_step, Pos, N}},  S) ->
    case erlang:get(log) of
        #log{status = ok} when S#state.cache_error =/= ok ->
            loop(cache_error(S, [From]));
        #log{status = ok} = L ->
            R = do_chunk_step(L, Pos, N),
            reply(From, R, S);
        #log{blocked_by = From} = L ->
            R = do_chunk_step(L, Pos, N),
            reply(From, R, S);
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {chunk_step, Pos, N}} | S#state.queue]})
    end;
handle({From, {change_notify, Pid, NewNotify}}, S) ->
    case erlang:get(log) of
        #log{status = ok} = L ->
            case do_change_notify(L, Pid, NewNotify) of
                {ok, L1} ->
                    erlang:put(log, L1),
                    reply(From, ok, S);
                Error ->
                    reply(From, Error, S)
            end;
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {change_notify, Pid, NewNotify}} | S#state.queue]})
    end;
handle({From, {change_header, NewHead}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok, format = Format} = L ->
            case check_head(NewHead, Format) of
                {ok, Head} ->
                    erlang:put(log, L#log{head = mk_head(Head, Format)}),
                    reply(From, ok, S);
                Error ->
                    reply(From, Error, S)
            end;
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {change_header, NewHead}} | S#state.queue]})
    end;
handle({From, {change_size, NewSize}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok, name = Name, type = Type} = L ->
            case check_size(Type, NewSize) of
                ok ->
                    case catch do_change_size(L, NewSize) of % does the put
                        ok ->
                            reply(From, ok, S);
                        {big, CurSize} ->
                            reply(From, {error, {new_size_too_small, Name, CurSize}}, S);
                        Else ->
                            reply(From, Else, state_err(S, Else))
                    end;
                not_ok ->
                    reply(From, {error, {badarg, size}}, S)
            end;
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, {change_size, NewSize}} | S#state.queue]})
    end;
handle({From, inc_wrap_file}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{type = halt, name = Name} ->
            reply(From, {error, {halt_log, Name}}, S);
        #log{status = ok} when S#state.cache_error =/= ok ->
            loop(cache_error(S, [From]));
        #log{status = ok} = L ->
            case catch do_inc_wrap_file(L) of
                {ok, L2, Lost} ->
                    erlang:put(log, L2),
                    notify_owners({wrap, Lost}),
                    reply(From, ok, S#state{cnt = S#state.cnt-Lost});
                {error, Error, L2} ->
                    erlang:put(log, L2),
                    reply(From, Error, state_err(S, Error))
            end;
        #log{status = {blocked, false}, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        #log{blocked_by = From, name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S);
        _ ->
            loop(S#state{queue = [{From, inc_wrap_file} | S#state.queue]})
    end;
handle({From, {reopen, NewFile, Head, F, A}}, S) ->
    case erlang:get(log) of
        #log{mode = read_only, name = Name} ->
            reply(From, {error, {read_only_mode, Name}}, S);
        #log{status = ok} when S#state.cache_error =/= ok ->
            loop(cache_error(S, [From]));
        #log{status = ok, filename = File, name = Name} = L when File =/= NewFile  ->
            case catch close_chronica_disk_log2(L) of
                closed ->
                    case catch rename_file(File, NewFile, L#log.type) of
                        ok ->
                            H = merge_head(Head, L#log.head),
                            case do_open((S#state.args)#arg{name = Name,
                                                            repair = truncate,
                                                            head = H,
                                                            file = File}) of
                                {ok, Res, L2, Cnt} ->
                                    erlang:put(log, L2#log{owners = L#log.owners,
                                                    head = L#log.head,
                                                    users = L#log.users}),
                                    notify_owners({truncated, S#state.cnt}),
                                    erlang:erase(is_full),
                                    case Res of
                                        {error, _} ->
                                            do_exit(S, From, Res,
                                                    ?failure(Res, F, A));
                                        _ ->
                                            reply(From, ok, S#state{cnt = Cnt})
                                    end;
                                Res ->
                                    do_exit(S, From, Res, ?failure(Res, F, A))
                            end;
                        Error ->
                            do_exit(S, From, Error, ?failure(Error, reopen, 2))
                    end;
                Error ->
                    do_exit(S, From, Error, ?failure(Error, F, A))
            end;
        #log{status = ok, name = Name} ->
            reply(From, {error, {same_file_name, Name}}, S);
        #log{name = Name} ->
            reply(From, {error, {blocked_log, Name}}, S)
    end;
handle({Server, {internal_open, A}}, S) ->
    case erlang:get(log) of
        undefined ->
            case do_open(A) of % does the put
                {ok, Res, L, Cnt} ->
                    erlang:put(log, opening_pid(A#arg.linkto, A#arg.notify, L)),
                    reply(Server, Res, S#state{args=A, cnt=Cnt});
                Res ->
                    do_fast_exit(S, Server, Res)
            end;
        #log{head = Head, name = Name} = L ->
            TestH = mk_head(A#arg.head, A#arg.format),
            case compare_arg(A#arg.options, S#state.args, TestH, Head) of
                ok ->
                    case add_pid(A#arg.linkto, A#arg.notify, L) of
                        {ok, L1} ->
                            erlang:put(log, L1),
                            reply(Server, {ok, Name}, S);
                        Error ->
                            reply(Server, Error, S)
                    end;
                Error ->
                    reply(Server, Error, S)
            end
    end;
handle({From, close}, S) ->
    case do_close(From, S) of
        {stop, S1} ->
            do_exit(S1, From, ok, normal);
        {continue, S1} ->
            reply(From, ok, S1)
    end;
handle({From, info}, S) ->
    reply(From, do_info(get(log), S#state.cnt), S);
handle({'EXIT', From, Reason}, #state{parent=From}=S) ->
    %% Parent orders shutdown.
    do_stop(S),
    exit(Reason);
handle({'EXIT', From, Reason}, #state{server=From}=S) ->
    %% The server is gone.
    do_stop(S),
    exit(Reason);
handle({'EXIT', From, _Reason}, S) ->
    L = erlang:get(log),
    case is_owner(From, L) of
        {true, _Notify} ->
            case close_owner(From, L, S) of
                {stop, S1} ->
                    do_stop(S1),
                    exit(normal);
                {continue, S1} ->
                    loop(S1)
            end;
        false ->
            %% 'users' is not decremented.
            S1 = do_unblock(From, erlang:get(log), S),
            loop(S1)
    end;
handle({system, From, Req}, S) ->
    sys:handle_system_msg(Req, From, S#state.parent, ?MODULE, [], S);
handle(_, S) ->
    loop(S).

sync_loop(From, S) ->
    log_loop(S, [], [], From).

%% Inlined.
log_loop(#state{cache_error = ok, messages = []}=S, Pids, Bins, Sync) ->
    receive
        Message ->
            log_loop(Message, Pids, Bins, Sync, S, erlang:get(log))
    after 0 ->
        loop(log_end(S, Pids, Bins, Sync))
    end;
log_loop(#state{cache_error = ok, messages = [M | Ms]}=S, Pids, Bins, Sync) ->
    S1 = S#state{messages = Ms},
    log_loop(M, Pids, Bins, Sync, S1, erlang:get(log));
log_loop(S, Pids, _Bins, _Sync) ->
    loop(cache_error(S, Pids)).

%% Items logged after the last sync request found are sync:ed as well.
log_loop({alog, B}, Pids, Bins, Sync, S, #log{format = internal}) ->
    %% {alog, _} allowed for the internal format only.
    log_loop(S, Pids, [B | Bins], Sync);
log_loop({balog, B}, Pids, Bins, Sync, S, _L) ->
    log_loop(S, Pids, [B | Bins], Sync);
log_loop({From, {log, B}}, Pids, Bins, Sync, S, #log{format = internal}) ->
    %% {log, _} allowed for the internal format only.
    log_loop(S, [From | Pids], [B | Bins], Sync);
log_loop({From, {blog, B}}, Pids, Bins, Sync, S, _L) ->
    log_loop(S, [From | Pids], [B | Bins], Sync);
log_loop({From, sync}, Pids, Bins, Sync, S, _L) ->
    log_loop(S, Pids, Bins, [From | Sync]);
log_loop(Message, Pids, Bins, Sync, S, _L) ->
    NS = log_end(S, Pids, Bins, Sync),
    handle(Message, NS).

log_end(S, [], [], Sync) ->
    log_end_sync(S, Sync);
log_end(S, Pids, Bins, Sync) ->
    case do_log(get(log), rflat(Bins)) of
        N when erlang:is_integer(N) ->
            replies(Pids, ok),
            S1 = (state_ok(S))#state{cnt = S#state.cnt+N},
            log_end_sync(S1, Sync);
        {error, {error, {full, _Name}}, N} when Pids =:= [] ->
            log_end_sync(state_ok(S#state{cnt = S#state.cnt + N}), Sync);
        {error, Error, N} ->
            replies(Pids, Error),
            state_err(S#state{cnt = S#state.cnt + N}, Error)
    end.

%% Inlined.
log_end_sync(S, []) ->
    S;
log_end_sync(S, Sync) ->
    Res = do_sync(get(log)),
    replies(Sync, Res),
    state_err(S, Res).

%% Inlined.
rflat([B]=L) when erlang:is_binary(B) -> L;
rflat([B]) -> B;
rflat(B) -> rflat(B, []).

rflat([B | Bs], L) when erlang:is_binary(B) ->
    rflat(Bs, [B | L]);
rflat([B | Bs], L) ->
    rflat(Bs, B ++ L);
rflat([], L) -> L.

%% -> {ok, Log} | {error, Error}
do_change_notify(L, Pid, Notify) ->
    case is_owner(Pid, L) of
        {true, Notify} ->
            {ok, L};
        {true, _OldNotify} when not erlang:is_boolean(Notify) ->
            {error, {badarg, notify}};
        {true, _OldNotify} ->
            Owners = lists:keydelete(Pid, 1, L#log.owners),
            L1 = L#log{owners = [{Pid, Notify} | Owners]},
            {ok, L1};
        false ->
            {error, {not_owner, Pid}}
    end.

%% -> {stop, S} | {continue, S}
do_close(Pid, S) ->
    L = erlang:get(log),
    case is_owner(Pid, L) of
        {true, _Notify} ->
            close_owner(Pid, L, S);
        false ->
            close_user(Pid, L, S)
    end.

%% -> {stop, S} | {continue, S}
close_owner(Pid, L, S) ->
    L1 = L#log{owners = lists:keydelete(Pid, 1, L#log.owners)},
    erlang:put(log, L1),
    S2 = do_unblock(Pid, erlang:get(log), S),
    unlink(Pid),
    do_close2(L1, S2).

%% -> {stop, S} | {continue, S}
close_user(Pid, #log{users = U} = L, S) when U > 0 ->
    L1 = L#log{users = U - 1},
    erlang:put(log, L1),
    S2 = do_unblock(Pid, erlang:get(log), S),
    do_close2(L1, S2);
close_user(_Pid, _L, S) ->
    {continue, S}.

do_close2(#log{users = 0, owners = []}, S) ->
    {stop, S};
do_close2(_L, S) ->
    {continue, S}.

%%-----------------------------------------------------------------
%% Callback functions for system messages handling.
%%-----------------------------------------------------------------
system_continue(_Parent, _, State) ->
    loop(State).

-spec system_terminate(_, _, _, #state{}) -> no_return().
system_terminate(Reason, _Parent, _, State) ->
    do_stop(State),
    exit(Reason).

%%-----------------------------------------------------------------
%% Temporay code for upgrade.
%%-----------------------------------------------------------------
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.


%%%----------------------------------------------------------------------
%%% Internal functions
%%%----------------------------------------------------------------------
-spec do_exit(#state{}, pid(), _, _) -> no_return().
do_exit(S, From, Message0, Reason) ->
    R = do_stop(S),
    Message = case S#state.cache_error of
                  Err when Err =/= ok -> Err;
                  _ when R =:= closed -> Message0;
                  _ when Message0 =:= ok -> R;
                  _ -> Message0
              end,
    chronica_disk_log_server:close(self()),
    replies(From, Message),
    ?PROFILE(ep:done()),
    exit(Reason).

-spec do_fast_exit(#state{}, pid(), _) -> no_return().
do_fast_exit(S, Server, Message) ->
    do_stop(S),
    Server ! {chronica_disk_log, erlang:self(), Message},
    exit(normal).

%% -> closed | Error
do_stop(S) ->
    proc_q(S#state.queue ++ S#state.messages),
    close_chronica_disk_log(get(log)).

proc_q([{From, _R}|Tail]) when erlang:is_pid(From) ->
    From ! {chronica_disk_log, erlang:self(), {error, chronica_disk_log_stopped}},
    proc_q(Tail);
proc_q([_|T]) -> %% async stuff
    proc_q(T);
proc_q([]) ->
    ok.

%% -> log()
opening_pid(Pid, Notify, L) ->
    {ok, L1} = add_pid(Pid, Notify, L),
    L1.

%% -> {ok, log()} | Error
add_pid(Pid, Notify, L) when erlang:is_pid(Pid) ->
    case is_owner(Pid, L) of
        false ->
            link(Pid),
            {ok, L#log{owners = [{Pid, Notify} | L#log.owners]}};
        {true, Notify}  ->
            %%{error, {pid_already_connected, Name}};
            {ok, L};
        {true, CurNotify} when Notify =/= CurNotify ->
            {error, {arg_mismatch, notify, CurNotify, Notify}}
    end;
add_pid(_NotAPid, _Notify, L) ->
    {ok, L#log{users = L#log.users + 1}}.

unblock_pid(#log{blocked_by=none}) ->
    ok;
unblock_pid(#log{blocked_by=V}=L) ->
    case is_owner(V, L) of
        {true, _Notify} -> ok;
        false -> unlink(V)
    end.

%% -> true | false
is_owner(Pid, L) ->
    case lists:keysearch(Pid, 1, L#log.owners) of
        {_value, {_Pid, Notify}} ->
            {true, Notify};
        false ->
            false
    end.

%% ok | throw(Error)
rename_file(File, NewFile, halt) ->
    file:rename(File, NewFile);
rename_file(File, NewFile, wrap) ->
    rename_file(wrap_file_extensions(File), File, NewFile, ok).

rename_file([Ext|Exts], File, NewFile, Res) ->
    NRes = case file:rename(add_ext(File, Ext), add_ext(NewFile, Ext)) of
               ok ->
                   Res;
               Else ->
                   Else
           end,
    rename_file(Exts, File, NewFile, NRes);
rename_file([], _File, _NewFiles, Res) -> Res.

%% "Old" error messages have been kept, arg_mismatch has been added.
%%-spec compare_arg(dlog_options(), #arg{},
compare_arg([], _A, none, _OrigHead) ->
    % no header option given
    ok;
compare_arg([], _A, Head, OrigHead) when Head =/= OrigHead ->
    {error, {arg_mismatch, head, OrigHead, Head}};
compare_arg([], _A, _Head, _OrigHead) ->
    ok;
compare_arg([{Attr, Val} | Tail], A, Head, OrigHead) ->
    case compare_arg(Attr, Val, A) of
        {not_ok, OrigVal} ->
            {error, {arg_mismatch, Attr, OrigVal, Val}};
        ok ->
            compare_arg(Tail, A, Head, OrigHead);
        Error ->
            Error
    end.

-spec compare_arg(atom(), _, #arg{}) ->
    'ok' | {'not_ok', _} | {'error', {atom(), _}}.
compare_arg(file, F, #arg{file = V} = A) when F =/= V ->
    {error, {name_already_open, A#arg.name}};
compare_arg(mode, read_only, #arg{mode = read_write} = A) ->
    {error, {open_read_write, A#arg.name}};
compare_arg(mode, read_write, #arg{mode = read_only} = A) ->
    {error, {open_read_only, A#arg.name}};
compare_arg(type, T, #arg{type = V} = A) when T =/= V ->
    {not_ok, A#arg.type};
compare_arg(format, F, #arg{format = V} = A) when F =/= V ->
    {not_ok, A#arg.format};
compare_arg(repair, R, #arg{repair = V} = A) when R =/= V ->
    %% not used, but check it anyway...
    {not_ok, A#arg.repair};
compare_arg(_Attr, _Val, _A) ->
    ok.

%% -> {ok, Res, log(), Cnt} | Error
do_open(A) ->
    L = #log{name = A#arg.name,
             filename = A#arg.file,
             size = A#arg.size,
             head = mk_head(A#arg.head, A#arg.format),
             mode = A#arg.mode,
             version = A#arg.version},
    do_open2(L, A).

mk_head({head, Term}, internal) -> {ok, erlang:term_to_binary(Term)};
mk_head({head, Bytes}, external) -> {ok, check_bytes(Bytes)};
mk_head(H, _) -> H.

terms2bins([T | Ts]) ->
    [erlang:term_to_binary(T) | terms2bins(Ts)];
terms2bins([]) ->
    [].

check_bytes_list(L) ->
    [check_bytes(I) || I <- L].

check_bytes(Binary) when erlang:is_binary(Binary) ->
    Binary;
check_bytes(Bytes) ->
    erlang:list_to_binary(Bytes).

%%-----------------------------------------------------------------
%% Change size of the logs in runtime.
%%-----------------------------------------------------------------
%% -> ok | {big, CurSize} | throw(Error)
do_change_size(#log{type = halt, extra = Halt}=L, NewSize) ->
    CurB = Halt#halt.curB,
    NewLog = L#log{extra = Halt#halt{size = NewSize}},
    if
        NewSize =:= infinity ->
            erlang:erase(is_full),
            erlang:put(log, NewLog),
            ok;
        CurB =< NewSize ->
            erlang:erase(is_full),
            erlang:put(log, NewLog),
            ok;
        true ->
            {big, CurB}
    end;
do_change_size(#log{type = wrap, extra = Extra, version = Version} = L, NewSize) ->
    {ok, Handle} = chronica_disk_log_1:change_size_wrap(Extra, NewSize, Version),
    erlang:erase(is_full),
    erlang:put(log, L#log{extra = Handle}),
    ok.

%% -> {ok, Head} | Error; Head = none | {head, H} | {M,F,A}
check_head({head, none}, _Format) ->
    {ok, none};
check_head({head_func, {M, F, A}}, _Format) when erlang:is_atom(M),
                                                 erlang:is_atom(F),
                                                 erlang:is_list(A) ->
    {ok, {M, F, A}};
check_head({head, Head}, external) ->
    case catch check_bytes(Head) of
        {'EXIT', _} ->
            {error, {badarg, head}};
        _ ->
            {ok, {head, Head}}
    end;
check_head({head, Term}, internal) ->
    {ok, {head, Term}};
check_head(_Head, _Format) ->
    {error, {badarg, head}}.

check_size(wrap, {NewMaxB, NewMaxF}) when
      erlang:is_integer(NewMaxB), erlang:is_integer(NewMaxF),
      NewMaxB > 0, NewMaxB =< ?MAX_BYTES, NewMaxF > 0, NewMaxF < ?MAX_FILES ->
    ok;
check_size(halt, NewSize) when erlang:is_integer(NewSize), NewSize > 0 ->
    ok;
check_size(halt, infinity) ->
    ok;
check_size(_, _) ->
    not_ok.

%%-----------------------------------------------------------------
%% Increment a wrap log.
%%-----------------------------------------------------------------
%% -> {ok, log(), Lost} | {error, Error, log()}
do_inc_wrap_file(#log{format = internal, extra = Handle, head = Head} = L) ->
    R = chronica_disk_log_1:mf_int_inc(Handle, Head),
    do_inc_wrap_file_(L, R);
do_inc_wrap_file(#log{format = external, extra = Handle, head = Head} = L) ->
    R = chronica_disk_log_1:mf_ext_inc(Handle, Head),
    do_inc_wrap_file_(L, R).
do_inc_wrap_file_(L, {ok, Handle, Lost}) ->
    {ok, L#log{extra = Handle}, Lost};
do_inc_wrap_file_(L, {error, Error, Handle}) ->
    {error, Error, L#log{extra = Handle}}.

%%-----------------------------------------------------------------
%% Open a log file.
%%-----------------------------------------------------------------
%% -> {ok, Reply, log(), Cnt} | Error
%% Note: the header is always written, even if the log size is too small.
do_open2(L, #arg{type = halt, format = internal, name = Name,
                 file = FName, repair = Repair, size = Size, mode = Mode}) ->
    case catch chronica_disk_log_1:int_open(FName, Repair, Mode, L#log.head) of
        {ok, {_Alloc, FdC, {NoItems, _NoBytes}, FileSize}} ->
            Halt = #halt{fdc = FdC, curB = FileSize, size = Size},
            {ok, {ok, Name}, L#log{format_type = halt_int, extra = Halt},
             NoItems};
        {repaired, FdC, Rec, Bad, FileSize} ->
            Halt = #halt{fdc = FdC, curB = FileSize, size = Size},
            {ok, {repaired, Name, {recovered, Rec}, {badbytes, Bad}},
             L#log{format_type = halt_int, extra = Halt},
             Rec};
        Error ->
            Error
    end;
do_open2(L, #arg{type = wrap, format = internal, size = {MaxB, MaxF},
                 name = Name, repair = Repair, file = FName, mode = Mode,
                 version = V}) ->
    case catch chronica_disk_log_1:mf_int_open(FName, MaxB, MaxF, Repair, Mode, L#log.head, V) of
        {ok, Handle, Cnt} ->
            {ok, {ok, Name}, L#log{type = wrap, format_type = wrap_int, extra = Handle}, Cnt};
        {repaired, Handle, Rec, Bad, Cnt} ->
            {ok, {repaired, Name, {recovered, Rec}, {badbytes, Bad}},
            L#log{type = wrap, format_type = wrap_int, extra = Handle}, Cnt};
        Error ->
            Error
    end;
do_open2(L, #arg{type = halt, format = external, file = FName, name = Name,
                 size = Size, repair = Repair, mode = Mode}) ->
    case catch chronica_disk_log_1:ext_open(FName, Repair, Mode, L#log.head) of
        {ok, {_Alloc, FdC, {NoItems, _NoBytes}, FileSize}} ->
            Halt = #halt{fdc = FdC, curB = FileSize, size = Size},
            {ok, {ok, Name},
             L#log{format_type = halt_ext, format = external, extra = Halt},
             NoItems};
        Error ->
            Error
    end;
do_open2(L, #arg{type = wrap, format = external, size = {MaxB, MaxF},
                 name = Name, file = FName, repair = Repair, mode = Mode,
                 version = V}) ->
    case catch chronica_disk_log_1:mf_ext_open(FName, MaxB, MaxF, Repair, Mode, L#log.head, V) of
        {ok, Handle, Cnt} ->
            {ok, {ok, Name}, L#log{type = wrap, format_type = wrap_ext, extra = Handle, format = external}, Cnt};
        Error ->
            Error
    end.

%% -> closed | Error
close_chronica_disk_log(undefined) ->
    closed;
close_chronica_disk_log(L) ->
    unblock_pid(L),
    F =
    fun({Pid, _}) ->
        unlink(Pid)
    end,
    lists:foreach(F, L#log.owners),
    R = (catch close_chronica_disk_log2(L)),
    erlang:erase(log),
    R.

-spec close_chronica_disk_log2(#log{}) -> 'closed'. % | throw(Error)

close_chronica_disk_log2(L) ->
    case L of
        #log{format_type = halt_int, mode = Mode, extra = Halt, filename = FN} ->
            chronica_disk_log_1:close(Halt#halt.fdc, FN, Mode);
        #log{format_type = wrap_int, mode = Mode, extra = Handle} ->
            chronica_disk_log_1:mf_int_close(Handle, Mode);
        #log{format_type = halt_ext, extra = Halt, filename = FN} ->
            chronica_disk_log_1:fclose(Halt#halt.fdc, FN);
        #log{format_type = wrap_ext, mode = Mode, extra = Handle} ->
            chronica_disk_log_1:mf_ext_close(Handle, Mode)
    end,
    closed.

do_format_error({error, Module, Error}) ->
    Module:format_error(Error);
do_format_error({error, Reason}) ->
    do_format_error(Reason);
do_format_error({Node, Error = {error, _Reason}}) ->
    lists:append(io_lib:format("~p: ", [Node]), do_format_error(Error));
do_format_error({badarg, Arg}) ->
    io_lib:format("The argument ~p is missing, not recognized or "
                  "not wellformed~n", [Arg]);
do_format_error({size_mismatch, OldSize, ArgSize}) ->
    io_lib:format("The given size ~p does not match the size ~p found on "
                  "the disk log size file~n", [ArgSize, OldSize]);
do_format_error({read_only_mode, Log}) ->
    io_lib:format("The disk log ~p has been opened read-only, but the "
                  "requested operation needs read-write access~n", [Log]);
do_format_error({format_external, Log}) ->
    io_lib:format("The requested operation can only be applied on internally "
                  "formatted disk logs, but ~p is externally formatted~n",
                  [Log]);
do_format_error({blocked_log, Log}) ->
    io_lib:format("The blocked disk log ~p does not queue requests, or "
                  "the log has been blocked by the calling process~n", [Log]);
do_format_error({full, Log}) ->
    io_lib:format("The halt log ~p is full~n", [Log]);
do_format_error({not_blocked, Log}) ->
    io_lib:format("The disk log ~p is not blocked~n", [Log]);
do_format_error({not_owner, Pid}) ->
    io_lib:format("The pid ~p is not an owner of the disk log~n", [Pid]);
do_format_error({not_blocked_by_pid, Log}) ->
    io_lib:format("The disk log ~p is blocked, but only the blocking pid "
                  "can unblock a disk log~n", [Log]);
do_format_error({new_size_too_small, Log, CurrentSize}) ->
    io_lib:format("The current size ~p of the halt log ~p is greater than the "
                  "requested new size~n", [CurrentSize, Log]);
do_format_error({halt_log, Log}) ->
    io_lib:format("The halt log ~p cannot be wrapped~n", [Log]);
do_format_error({same_file_name, Log}) ->
    io_lib:format("Current and new file name of the disk log ~p "
                  "are the same~n", [Log]);
do_format_error({arg_mismatch, Option, FirstValue, ArgValue}) ->
    io_lib:format("The value ~p of the disk log option ~p does not match "
                  "the current value ~p~n", [ArgValue, Option, FirstValue]);
do_format_error({name_already_open, Log}) ->
    io_lib:format("The disk log ~p has already opened another file~n", [Log]);
do_format_error({node_already_open, Log}) ->
    io_lib:format("The distribution option of the disk log ~p does not match "
                  "already open log~n", [Log]);
do_format_error({open_read_write, Log}) ->
    io_lib:format("The disk log ~p has already been opened read-write~n",
                  [Log]);
do_format_error({open_read_only, Log}) ->
    io_lib:format("The disk log ~p has already been opened read-only~n",
                  [Log]);
do_format_error({not_internal_wrap, Log}) ->
    io_lib:format("The requested operation cannot be applied since ~p is not "
                  "an internally formatted disk log~n", [Log]);
do_format_error(no_such_log) ->
    io_lib:format("There is no disk log with the given name~n", []);
do_format_error(nonode) ->
    io_lib:format("There seems to be no node up that can handle "
                  "the request~n", []);
do_format_error(nodedown) ->
    io_lib:format("There seems to be no node up that can handle "
                  "the request~n", []);
do_format_error({corrupt_log_file, FileName}) ->
    io_lib:format("The disk log file \"~s\" contains corrupt data~n",
                  [FileName]);
do_format_error({need_repair, FileName}) ->
    io_lib:format("The disk log file \"~s\" has not been closed properly and "
                  "needs repair~n", [FileName]);
do_format_error({not_a_log_file, FileName}) ->
    io_lib:format("The file \"~s\" is not a wrap log file~n", [FileName]);
do_format_error({invalid_header, InvalidHeader}) ->
    io_lib:format("The disk log header is not wellformed: ~p~n",
                  [InvalidHeader]);
do_format_error(end_of_log) ->
    io_lib:format("An attempt was made to step outside a not yet "
                  "full wrap log~n", []);
do_format_error({invalid_index_file, FileName}) ->
    io_lib:format("The wrap log index file \"~s\" cannot be used~n",
                  [FileName]);
do_format_error({no_continuation, BadCont}) ->
    io_lib:format("The term ~p is not a chunk continuation~n", [BadCont]);
do_format_error({file_error, FileName, Reason}) ->
    io_lib:format("\"~s\": ~p~n", [FileName, file:format_error(Reason)]);
do_format_error(E) ->
    io_lib:format("~p~n", [E]).

do_info(L, Cnt) ->
    #log{name = Name, type = Type, mode = Mode, filename = File,
         extra = Extra, status = Status, owners = Owners, users = Users,
         format = Format, head = Head} = L,
    Size = case Type of
               wrap ->
                   chronica_disk_log_1:get_wrap_size(Extra);
               halt ->
                   Extra#halt.size
           end,
    Distribution =
    case chronica_disk_log_server:get_log_pids(Name) of
        {local, _Pid} ->
            local;
        {distributed, Pids} ->
            [node(P) || P <- Pids];
        undefined -> % "cannot happen"
            []
    end,
    RW = case Type of
             wrap when Mode =:= read_write ->
                 #handle{curB = CurB, curF = CurF,
                         cur_cnt = CurCnt, acc_cnt = AccCnt,
                         noFull = NoFull, accFull = AccFull} = Extra,
                 NewAccFull = AccFull + NoFull,
                 NewExtra = Extra#handle{noFull = 0, accFull = NewAccFull},
                 erlang:put(log, L#log{extra = NewExtra}),
                 [{no_current_bytes, CurB},
                  {no_current_items, CurCnt},
                  {no_items, Cnt},
                  {no_written_items, CurCnt + AccCnt},
                  {current_file, CurF},
                  {no_overflows, {NewAccFull, NoFull}}
                 ];
             halt when Mode =:= read_write ->
                 IsFull = case erlang:get(is_full) of
                              undefined -> false;
                              _ -> true
                          end,
                 [{full, IsFull},
                  {no_written_items, Cnt}
                 ];
             _ when Mode =:= read_only ->
                 []
         end,
    HeadL = case Mode of
                read_write ->
                    [{head, Head}];
                read_only ->
                    []
            end,
    Common = [{name, Name},
              {file, File},
              {type, Type},
              {format, Format},
              {size, Size},
              {items, Cnt}, % kept for "backward compatibility" (undocumented)
              {owners, Owners},
              {users, Users}] ++
    HeadL ++
    [{mode, Mode},
     {status, Status},
     {node, erlang:node()},
     {distributed, Distribution}
    ],
    Common ++ RW.

do_block(Pid, QueueLogRecs, L) ->
    L2 = L#log{status = {blocked, QueueLogRecs}, blocked_by = Pid},
    erlang:put(log, L2),
    case is_owner(Pid, L2) of
        {true, _Notify} ->
            ok;
        false ->
            link(Pid)
    end.

do_unblock(Pid, #log{blocked_by=Pid}=L, S) ->
    do_unblock(L, S);
do_unblock(_Pid, _L, S) ->
    S.

do_unblock(L, S) ->
    unblock_pid(L),
    L2 = L#log{blocked_by = none, status = ok},
    erlang:put(log, L2),
    %% Since the block request is synchronous, and the blocking
    %% process is the only process that can unblock, all requests in
    %% 'messages' will have been put in 'queue' before the unblock
    %% request is granted.
    [] = S#state.messages, % assertion
    S#state{queue = [], messages = lists:reverse(S#state.queue)}.

-spec do_log(#log{}, [binary()]) -> integer() | {'error', _, integer()}.

do_log(#log{type = halt, format = Format, extra = Halt, name = Name}=L, B) ->
    #halt{curB = CurSize, size = Sz} = Halt,
    {Bs, BSize} = bsize(B, Format),
    case erlang:get(is_full) of
        true ->
            {error, {error, {full, Name}}, 0};
        undefined when Sz =:= infinity; CurSize + BSize =< Sz ->
            halt_write(Halt, L, B, Bs, BSize);
        undefined ->
            halt_write_full(L, B, Format, 0)
    end;
do_log(#log{format_type = wrap_int, extra = Extra, head=Head}=L, B) ->
    case chronica_disk_log_1:mf_int_log(Extra, B, Head) of
        {ok, Handle, Logged, Lost, Wraps} ->
            notify_owners_wrap(Wraps),
            erlang:put(log, L#log{extra = Handle}),
            Logged - Lost;
        {ok, Handle, Logged} ->
            erlang:put(log, L#log{extra = Handle}),
            Logged;
        {error, Error, Handle, Logged, Lost} ->
            erlang:put(log, L#log{extra = Handle}),
            {error, Error, Logged - Lost}
    end;
do_log(#log{format_type = wrap_ext, extra = Extra, head=Head}=L, B) ->
    case chronica_disk_log_1:mf_ext_log(Extra, B, Head) of
        {ok, Handle, Logged, Lost, Wraps} ->
            notify_owners_wrap(Wraps),
            erlang:put(log, L#log{extra = Handle}),
            Logged - Lost;
        {ok, Handle, Logged} ->
            erlang:put(log, L#log{extra = Handle}),
            Logged;
        {error, Error, Handle, Logged, Lost} ->
            erlang:put(log, L#log{extra = Handle}),
            {error, Error, Logged - Lost}
    end.

bsize(B, external) ->
    {B, xsz(B, 0)};
bsize(B, internal) ->
    chronica_disk_log_1:logl(B).

xsz([B|T], Sz) -> xsz(T, byte_size(B) + Sz);
xsz([], Sz) -> Sz.

halt_write_full(L, [Bin | Bins], Format, N) ->
    B = [Bin],
    {Bs, BSize} = bsize(B, Format),
    Halt = L#log.extra,
    #halt{curB = CurSize, size = Sz} = Halt,
    if
        CurSize + BSize =< Sz ->
            case halt_write(Halt, L, B, Bs, BSize) of
                N1 when erlang:is_integer(N1) ->
                    halt_write_full(get(log), Bins, Format, N+N1);
                Error ->
                    Error
            end;
        true ->
            halt_write_full(L, [], Format, N)
    end;
halt_write_full(#log{name = Name}, _Bs, _Format, N) ->
    erlang:put(is_full, true),
    notify_owners(full),
    {error, {error, {full, Name}}, N}.

halt_write(Halt, L, B, Bs, BSize) ->
    case chronica_disk_log_1:fwrite(Halt#halt.fdc, L#log.filename, Bs, BSize) of
        {ok, NewFdC} ->
            NCurB = Halt#halt.curB + BSize,
            NewHalt = Halt#halt{fdc = NewFdC, curB = NCurB},
            erlang:put(log, L#log{extra = NewHalt}),
            length(B);
        {Error, NewFdC} ->
            erlang:put(log, L#log{extra = Halt#halt{fdc = NewFdC}}),
            {error, Error, 0}
    end.

%% -> ok | Error
do_write_cache(#log{filename = FName, type = halt, extra = Halt} = Log) ->
    {Reply, NewFdC} = chronica_disk_log_1:write_cache(Halt#halt.fdc, FName),
    erlang:put(log, Log#log{extra = Halt#halt{fdc = NewFdC}}),
    Reply;
do_write_cache(#log{type = wrap, extra = Handle} = Log) ->
    {Reply, NewHandle} = chronica_disk_log_1:mf_write_cache(Handle),
    erlang:put(log, Log#log{extra = NewHandle}),
    Reply.

%% -> ok | Error
do_sync(#log{filename = FName, type = halt, extra = Halt} = Log) ->
    {Reply, NewFdC} = chronica_disk_log_1:sync(Halt#halt.fdc, FName),
    erlang:put(log, Log#log{extra = Halt#halt{fdc = NewFdC}}),
    Reply;
do_sync(#log{type = wrap, extra = Handle} = Log) ->
    {Reply, NewHandle} = chronica_disk_log_1:mf_sync(Handle),
    erlang:put(log, Log#log{extra = NewHandle}),
    Reply.

%% -> ok | Error | throw(Error)
do_trunc(#log{type = halt, filename = FName, extra = Halt, format = Format} = L, Head) ->
    FdC = Halt#halt.fdc,
    {Reply1, FdC2} =
    case Format of
        internal ->
            chronica_disk_log_1:truncate(FdC, FName, Head);
        external ->
            case chronica_disk_log_1:truncate_at(FdC, FName, bof) of
                {ok, NFdC} when Head =:= none ->
                    {ok, NFdC};
                {ok, NFdC} ->
                    {ok, H} = Head,
                    chronica_disk_log_1:fwrite(NFdC, FName, H, byte_size(H));
                R ->
                    R
            end
    end,
    {Reply, NewHalt} =
    case chronica_disk_log_1:position(FdC2, FName, cur) of
        {ok, NewFdC, FileSize} when Reply1 =:= ok ->
            {ok, Halt#halt{fdc = NewFdC, curB = FileSize}};
        {Reply2, NewFdC} ->
            {Reply2, Halt#halt{fdc = NewFdC}};
        {ok, NewFdC, _} ->
            {Reply1, Halt#halt{fdc = NewFdC}}
    end,
    erlang:put(log, L#log{extra = NewHalt}),
    Reply;
do_trunc(#log{type = wrap, extra = Handle, head = OldHead} = L, Head) ->
    {MaxB, MaxF} = chronica_disk_log_1:get_wrap_size(Handle),
    ok = do_change_size(L, {MaxB, 1}),
    NewLog = trunc_wrap((get(log))#log{head = Head}),
    %% Just to remove all files with suffix > 1:
    NewLog2 = trunc_wrap(NewLog),
    NewHandle = (NewLog2#log.extra)#handle{noFull = 0, accFull = 0},
    do_change_size(NewLog2#log{extra = NewHandle, head = OldHead},
                   {MaxB, MaxF}).

trunc_wrap(L) ->
    case do_inc_wrap_file(L) of
        {ok, L2, _Lost} ->
            L2;
        {error, Error, _L2} ->
            throw(Error)
    end.

do_chunk(#log{format_type = halt_int, extra = Halt, mode=Mode} = L, Pos, B, N) ->
    FdC = Halt#halt.fdc,
    {NewFdC, Reply} =
    case Mode of
        read_only ->
            chronica_disk_log_1:chunk_read_only(FdC, L#log.filename, Pos, B, N);
        read_write ->
            chronica_disk_log_1:chunk(FdC, L#log.filename, Pos, B, N)
    end,
    erlang:put(log, L#log{extra = Halt#halt{fdc = NewFdC}}),
    Reply;
do_chunk(#log{format_type = wrap_int, mode = read_only, extra = Handle} = Log, Pos, B, N) ->
    {NewHandle, Reply} = chronica_disk_log_1:mf_int_chunk_read_only(Handle, Pos, B, N),
    erlang:put(log, Log#log{extra = NewHandle}),
    Reply;
do_chunk(#log{format_type = wrap_int, extra = Handle} = Log, Pos, B, N) ->
    {NewHandle, Reply} = chronica_disk_log_1:mf_int_chunk(Handle, Pos, B, N),
    erlang:put(log, Log#log{extra = NewHandle}),
    Reply;
do_chunk(Log, _Pos, _B, _) ->
    {error, {format_external, Log#log.name}}.

do_chunk_step(#log{format_type = wrap_int, extra = Handle}, Pos, N) ->
    chronica_disk_log_1:mf_int_chunk_step(Handle, Pos, N);
do_chunk_step(Log, _Pos, _N) ->
    {error, {not_internal_wrap, Log#log.name}}.

%% Inlined.
replies(Pids, Reply) ->
    M = {chronica_disk_log, erlang:self(), Reply},
    send_reply(Pids, M).

send_reply(Pid, M) when erlang:is_pid(Pid) ->
    Pid ! M;
send_reply([Pid | Pids], M) ->
    Pid ! M,
    send_reply(Pids, M);
send_reply([], _M) ->
    ok.

reply(To, Reply, S) ->
    To ! {chronica_disk_log, erlang:self(), Reply},
    loop(S).

req(Log, R) ->
    case chronica_disk_log_server:get_log_pids(Log) of
        {local, Pid} ->
            monitor_request(Pid, R);
        undefined ->
            {error, no_such_log};
        {distributed, Pids} ->
            multi_req({self(), R}, Pids)
    end.

multi_req(Msg, Pids) ->
    Refs =
    lists:map(fun(Pid) ->
                      Ref = erlang:monitor(process, Pid),
                      Pid ! Msg,
                      {Pid, Ref}
              end, Pids),
    lists:foldl(fun({Pid, Ref}, Reply) ->
                        receive
                            {'DOWN', Ref, process, Pid, _Info} ->
                                Reply;
                            {chronica_disk_log, Pid, _Reply} ->
                                erlang:demonitor(Ref),
                                receive
                                    {'DOWN', Ref, process, Pid, _Reason} ->
                                        ok
                                after 0 ->
                                          ok
                                end
                        end
                end, {error, nonode}, Refs).

sreq(Log, R) ->
    case nearby_pid(Log, erlang:node()) of
        undefined ->
            {error, no_such_log};
        Pid ->
            monitor_request(Pid, R)
    end.

%% Local req - always talk to log on Node
lreq(Log, R, Node) ->
    case nearby_pid(Log, Node) of
        Pid when erlang:is_pid(Pid), erlang:node(Pid) =:= Node ->
            monitor_request(Pid, R);
        _Else ->
            {error, no_such_log}
    end.

nearby_pid(Log, Node) ->
    case chronica_disk_log_server:get_log_pids(Log) of
        undefined ->
            undefined;
        {local, Pid} ->
            Pid;
        {distributed, Pids} ->
            get_near_pid(Pids, Node)
    end.

-spec get_near_pid([pid(), ...], erlang:node()) -> pid().
get_near_pid([Pid | _], Node) when erlang:node(Pid) =:= Node -> Pid;
get_near_pid([Pid], _ ) -> Pid;
get_near_pid([_ | T], Node) -> get_near_pid(T, Node).

monitor_request(Pid, Req) ->
    Ref = erlang:monitor(process, Pid),
    Pid ! {self(), Req},
    receive
        {'DOWN', Ref, process, Pid, _Info} ->
            {error, no_such_log};
        {chronica_disk_log, Pid, Reply} ->
            erlang:demonitor(Ref),
            receive
                {'DOWN', Ref, process, Pid, _Reason} ->
                    Reply
            after 0 ->
                      Reply
            end
    end.

req2(Pid, R) ->
    monitor_request(Pid, R).

merge_head(none, Head) ->
    Head;
merge_head(Head, _) ->
    Head.

%% -> List of extensions of existing files (no dot included) | throw(FileError)
wrap_file_extensions(File) ->
    {_CurF, _CurFSz, _TotSz, NoOfFiles} =
    chronica_disk_log_1:read_index_file(File),
    Fs = if
             NoOfFiles >= 1 ->
                 lists:seq(1, NoOfFiles);
             NoOfFiles =:= 0 ->
                 []
         end,
    Fun = fun(Ext) ->
                  case file:read_file_info(add_ext(File, Ext)) of
                      {ok, _} ->
                          true;
                      _Else ->
                          false
                  end
          end,
    lists:filter(Fun, ["idx", "siz" | Fs]).

add_ext(File, Ext) ->
    lists:concat([File, ".", Ext]).

notify(Log, R) ->
    case chronica_disk_log_server:get_log_pids(Log) of
        undefined ->
            {error, no_such_log};
        {local, Pid} ->
            Pid ! R,
            ok;
        {distributed, Pids} ->
            lists:foreach(fun(Pid) -> Pid ! R end, Pids),
            ok
    end.

notify_owners_wrap([]) ->
    ok;
notify_owners_wrap([N | Wraps]) ->
    notify_owners({wrap, N}),
    notify_owners_wrap(Wraps).

notify_owners(Note) ->
    L = erlang:get(log),
    Msg = {chronica_disk_log, erlang:node(), L#log.name, Note},
    lists:foreach(fun({Pid, true}) -> Pid ! Msg;
                     (_) -> ok
                  end, L#log.owners).

cache_error(S, Pids) ->
    Error = S#state.cache_error,
    replies(Pids, Error),
    state_err(S#state{cache_error = ok}, Error).

state_ok(S) ->
    state_err(S, ok).

-spec state_err(#state{}, dlog_state_error()) -> #state{}.

state_err(#state{error_status = Err} = S, Err) -> S;
state_err(S, Err) ->
    notify_owners({error_status, Err}),
    S#state{error_status = Err}.
