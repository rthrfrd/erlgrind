-module(erlgrind).

-export([main/1]).

%%% Copyright (c) 2011-2014
%%% Isac Sacchi e Souza <isacssouza@gmail.com>
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%%
%%% 1. Redistributions of source code must retain the above copyright notice, this
%%%    list of conditions and the following disclaimer.
%%% 2. Redistributions in binary form must reproduce the above copyright notice,
%%%    this list of conditions and the following disclaimer in the documentation
%%%    and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
%%% WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
%%% ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
%%% (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
%%% LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
%%% ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
%%% (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
%%% SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

%%%-------------------------------------------------------------------
%%% File    : erlgrind
%%% Author  : Isac Sacchi e Souza <isacssouza@gmail.com>
%%% Description : Escript to convert fprof output to callgrind output.
%%%
%%% Created : 2011-09-04
%%%-------------------------------------------------------------------

-record(opts, {pid = false :: boolean(),
               in_file :: string(),
               in_file_format :: trace | analysis,
               out_file :: string()}).

main(Params) ->
    try parse_params(Params, #opts{}) of
        Opts ->
            AnalysisFile = maybe_convert_trace(Opts),
            {ok, OutFile} = file:open(Opts#opts.out_file, [write]),
            {ok, Terms} = file:consult(AnalysisFile),
            io:format(OutFile, "events: Time~n", []),
            process_terms(OutFile, Terms, Opts)
    catch
        throw:help ->
            print_usage();
        _:Reason ->
            io:format("Error. ~s.~n", [Reason]),
            print_usage()
    end.

process_terms(OutFile, [], _Opts) ->
    file:close(OutFile);
process_terms(OutFile, [{analysis_options, _Opt} | Rest], Opts) ->
    process_terms(OutFile, Rest, Opts);
process_terms(OutFile, [[{totals, _Cnt, Acc, _Own}] | Rest], Opts) ->
    io:format(OutFile, "summary: ~w~n", [trunc(Acc*1000)]),
    process_terms(OutFile, Rest, Opts);
process_terms(OutFile, [[{Pid, _Cnt, _Acc, _Own} | _T] | Rest], Opts)
        when is_list(Pid) and (Opts#opts.pid =:= true) ->
    io:format(OutFile, "ob=~s~n", [Pid]),
    process_terms(OutFile, Rest, Opts);
process_terms(OutFile, [List | Rest], Opts) when is_list(List) ->
    process_terms(OutFile, Rest, Opts);
process_terms(OutFile, [Entry | Rest], Opts) ->
    process_entry(OutFile, Entry),
    process_terms(OutFile, Rest, Opts).

process_entry(OutFile, {_CallingList, Actual, CalledList}) ->
    process_actual(OutFile, Actual),
    process_called_list(OutFile, CalledList).

process_actual(OutFile, {Func, _Cnt, _Acc, _Own} = Actual) ->
    File = get_file(Func),
    Time = actual_time(Actual),
    io:format(OutFile, "fl=~w~n", [File]),
    io:format(OutFile, "fn=~w~n", [Func]),
    io:format(OutFile, "1 ~w~n", [Time]).

actual_time({suspend, _Cnt, Acc, _Own}) ->
    %% fprof doesn't include suspend time as own time, but kcachegrind needs a time value here
    %% or total percents will add up to more than 100
    trunc(Acc*1000);
actual_time({_Func, _Cnt, _Acc, Own}) ->
    trunc(Own*1000).

process_called_list(_, []) ->
    ok;
process_called_list(OutFile, [Called | Rest]) ->
    process_called(OutFile, Called),
    process_called_list(OutFile, Rest).

process_called(OutFile, {Func, Cnt, Acc, _Own}) ->
    File = get_file(Func),
    io:format(OutFile, "cfl=~w~n", [File]),
    io:format(OutFile, "cfn=~w~n", [Func]),
    io:format(OutFile, "calls=~w 1~n", [Cnt]),
    io:format(OutFile, "1 ~w~n", [trunc(Acc*1000)]).

get_file({Mod, _Func, _Arity}) ->
    Mod;
get_file(_Func) ->
    pseudo.

parse_params(["-h" | _], _) ->
    throw(help);
parse_params(["-p" | Rest], Opts) ->
    parse_params(Rest, Opts#opts{pid=true});
parse_params([[$- | _] = Opt | _], _) ->
    throw(io_lib:format("Invalid option \"~s\"", [Opt]));
parse_params([Arg | Rest], #opts{in_file=undefined} = Opts) ->
    parse_params(Rest, Opts#opts{in_file=Arg,
                                 in_file_format = infile_format(Arg)});
parse_params([Arg | Rest], #opts{out_file=undefined} = Opts) ->
    parse_params(Rest, Opts#opts{out_file=Arg});
parse_params([], #opts{out_file=undefined, in_file=InFileName} = Opts) ->
    %% No outfile specified:
    %% generate output filename by replacing file extension with ".cgrind"
    OutFileName = replace_extension(InFileName, ".cgrind"),
    parse_params([], Opts#opts{out_file=OutFileName});
parse_params([], Opts) ->
    Opts;
parse_params(Other, _) ->
    throw(io_lib:format("Invalid argument \"~s\"", [Other])).


infile_format(InFileName) ->
    case filename:extension(InFileName) of
        ".trace" ->
            trace;
        ".analysis" ->
            analysis;
        _ ->
            % if we can't identify the extension, default to analysis
            analysis
    end.

maybe_convert_trace(#opts{in_file_format=analysis, in_file=InFileName}) ->
    InFileName;
maybe_convert_trace(#opts{in_file_format=trace, in_file=InFileName}) ->
    AnalysisFileName = replace_extension(InFileName, ".analysis"),
    fprof:profile([{file, InFileName}]),
    fprof:analyse([{dest, AnalysisFileName}]),
    AnalysisFileName.

replace_extension(Filename, NewExtension) ->
    Idx = string:rchr(Filename, $.),
    BaseFile = string:substr(Filename, 1, Idx - 1),
    BaseFile ++ NewExtension.

print_usage() ->
    io:format("Usage: erlgrind [Options] <input file .trace/.analysis> [<output file>]~n"),
    io:format("Options:~n"
              "\t-p\tuse process pid as ELF object~n"
              "\t-h\tshow this message~n").
