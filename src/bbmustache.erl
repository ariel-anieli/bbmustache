%% @copyright 2015 Hinagiku Soranoba All Rights Reserved.
%%
%% @doc Binary pattern match Based Mustach template engine for Erlang/OTP.
%%
%% This library support all of mustache syntax. <br />
%% Please refer to [the documentation for how to use the mustache](http://mustache.github.io/mustache.5.html) as the need arises.
%%

-module(bbmustache).

%%----------------------------------------------------------------------------------------------------------------------
%% Exported API
%%----------------------------------------------------------------------------------------------------------------------
-export([
         render/2,
         render/3,
         parse_binary/1,
         parse_file/1,
         compile/2,
         compile/3
        ]).

-export_type([
              template/0,
              data/0,
              option/0
             ]).

%%----------------------------------------------------------------------------------------------------------------------
%% Defines & Records & Types
%%----------------------------------------------------------------------------------------------------------------------

-define(PARSE_ERROR, incorrect_format).
-define(FILE_ERROR,  file_not_found).
-define(IIF(Cond, TValue, FValue),
        case Cond of true -> TValue; false -> FValue end).

-define(ADD(X, Y), ?IIF(X =:= <<>>, Y, [X | Y])).
-define(START_TAG, <<"{{">>).
-define(STOP_TAG,  <<"}}">>).

-type key()    :: binary().
-type source() :: binary().
%% If you use lamda expressions, the original text is necessary.
%%
%% ```
%% e.g.
%%   template:
%%     {{#lamda}}a{{b}}c{{/lamda}}
%%   parse result:
%%     {'#', <<"lamda">>, [<<"a">>, {'n', <<"b">>}, <<"c">>], <<"a{{b}}c">>}
%% '''
%%
%% NOTE:
%%   Since the binary reference is used internally, it is not a capacitively large waste.
%%   However, the greater the number of tags used, it should use the wasted memory.
-type tag()    :: {n,   key()}
                | {'&', key()}
                | {'#', key(), [tag()], source()}
                | {'^', key(), [tag()]}
                | {'>', key()}
                | binary(). % plain text

-record(?MODULE,
        {
          data          :: [tag()],
          partials = [] :: [{key(), [tag()]}],
          options  = [] :: [option()]
        }).

-opaque template() :: #?MODULE{}.
%% @see parse_binary/1
%% @see parse_file/1

-record(state,
        {
          dirname  = <<>>       :: file:filename_all(),
          start    = ?START_TAG :: binary(),
          stop     = ?STOP_TAG  :: binary(),
          partials = []         :: [key()]
        }).
-type state() :: #state{}.

-type data_key()   :: atom() | binary() | string().
%% You can choose one from these as the type of key in {@link data/0}.

-type data_value() :: data() | iodata() | number() | atom() | fun((data(), function()) -> iodata()).
%% Function is intended to support a lambda expression.

-type assoc_data() :: [{atom(), data_value()}] | [{binary(), data_value()}] | [{string(), data_value()}].

-type option()     :: {key_type, atom | binary | string}.
%% - key_type: Specify the type of the key in {@link data/0}. Default value is `string'.

-ifdef(namespaced_types).
-type maps_data() :: #{atom() => data_value()} | #{binary() => data_value()} | #{string() => data_value()}.
-type data()      :: maps_data() | assoc_data().
-else.
-type data()      :: assoc_data().
-endif.
%% All key in assoc list or maps must be same type.
%% @see render/2
%% @see compile/2

-type endtag()    :: {endtag, {state(), EndTag :: binary(), LastTagSize :: non_neg_integer(), Rest :: binary(), Result :: [tag()]}}.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported Functions
%%----------------------------------------------------------------------------------------------------------------------

%% @equiv render(Bin, Data, [])
-spec render(binary(), data()) -> binary().
render(Bin, Data) ->
    render(Bin, Data, []).

%% @equiv compile(parse_binary(Bin), Data, Options)
-spec render(binary(), data(), [option()]) -> binary().
render(Bin, Data, Options) ->
    compile(parse_binary(Bin), Data, Options).

%% @doc Create a {@link template/0} from a binary.
-spec parse_binary(binary()) -> template().
parse_binary(Bin) when is_binary(Bin) ->
    parse_binary_impl(#state{}, Bin).

%% @doc Create a {@link template/0} from a file.
-spec parse_file(file:filename_all()) -> template().
parse_file(Filename) ->
    State = #state{dirname = filename:dirname(Filename)},
    case to_binary(filename:extension(Filename)) of
        <<".mustache">> = Ext ->
            Partials = [Key = to_binary(filename:basename(Filename, Ext))],
            parse_binary_impl(State#state{partials = Partials}, #?MODULE{data = [{'>', Key}]});
        _ ->
            case file:read_file(Filename) of
                {ok, Bin} -> parse_binary_impl(State, Bin);
                _         -> error(?FILE_ERROR, [Filename])
            end
    end.

%% @equiv compile(Template, Data, [])
-spec compile(template(), data()) -> binary().
compile(Template, Data) ->
    compile(Template, Data, []).

%% @doc Embed the data in the template.
%%
%% ```
%% 1> Template = bbmustache:parse_binary(<<"{{name}}">>).
%% 2> bbmustache:compile(Template, #{"name" => "Alice"}).
%% <<"Alice">>
%% '''
%% Data support assoc list or maps (OTP17 or later). <br />
%% All key in assoc list or maps must be same type.
-spec compile(template(), data(), [option()]) -> binary().
compile(#?MODULE{data = Tags} = T, Data, Options) ->
    case check_data_type(Data) of
        false -> error(function_clause, [T, Data]);
        _     ->
            Ret = compile_impl(Tags, Data, [], T#?MODULE{options = Options, data = []}),
            iolist_to_binary(lists:reverse(Ret))
    end.

%%----------------------------------------------------------------------------------------------------------------------
%% Internal Function
%%----------------------------------------------------------------------------------------------------------------------

%% @doc {@link compile/2}
%%
%% ATTENTION: The result is a list that is inverted.
-spec compile_impl(Template :: [tag()], data(), Result :: iodata(), #?MODULE{}) -> iodata().
compile_impl([], _, Result, _) ->
    Result;
compile_impl([{n, Key} | T], Map, Result, State) ->
    compile_impl(T, Map, ?ADD(escape(to_iodata(get_data_recursive(Key, Map, <<>>, State))), Result), State);
compile_impl([{'&', Key} | T], Map, Result, State) ->
    compile_impl(T, Map, ?ADD(to_iodata(get_data_recursive(Key, Map, <<>>, State)), Result), State);
compile_impl([{'#', Key, Tags, Source} | T], Map, Result, State) ->
    Value = get_data_recursive(Key, Map, false, State),
    case check_data_type(Value) of
        true ->
            compile_impl(T, Map, compile_impl(Tags, Value, Result, State), State);
        _ when is_list(Value) ->
            compile_impl(T, Map, lists:foldl(fun(X, Acc) -> compile_impl(Tags, X, Acc, State) end,
                                             Result, Value), State);
        _ when Value =:= false ->
            compile_impl(T, Map, Result, State);
        _ when is_function(Value, 2) ->
            Ret = Value(Source, fun(Text) -> render(Text, Map, State#?MODULE.options) end),
            compile_impl(T, Map, ?ADD(Ret, Result), State);
        _ ->
            compile_impl(T, Map, compile_impl(Tags, Map, Result, State), State)
    end;
compile_impl([{'^', Key, Tags} | T], Map, Result, State) ->
    Value = get_data_recursive(Key, Map, false, State),
    case Value =:= [] orelse Value =:= false of
        true  -> compile_impl(T, Map, compile_impl(Tags, Map, Result, State), State);
        false -> compile_impl(T, Map, Result, State)
    end;
compile_impl([{'>', Key} | T], Map, Result0, #?MODULE{partials = Partials} = State) ->
    case proplists:get_value(Key, Partials) of
        undefined -> compile_impl(T, Map, Result0, State);
        PartialT  ->
            compile_impl(T, Map, compile_impl(PartialT, Map, Result0, State), State)
    end;
compile_impl([Bin | T], Map, Result, State) ->
    compile_impl(T, Map, ?ADD(Bin, Result), State).

%% @see parse_binary/1
-spec parse_binary_impl(state(), Input | #?MODULE{}) -> template() when
      Input :: binary().
parse_binary_impl(#state{partials = []}, Template = #?MODULE{}) ->
    Template;
parse_binary_impl(State = #state{partials = [P | PartialKeys]}, Template = #?MODULE{partials = Partials}) ->
    case proplists:is_defined(P, Partials) of
        true  -> parse_binary_impl(State#state{partials = PartialKeys}, Template);
        false ->
            Filename0 = <<P/binary, ".mustache">>,
            Dirname   = State#state.dirname,
            Filename  = ?IIF(Dirname =:= <<>>, Filename0, filename:join([Dirname, Filename0])),
            case file:read_file(Filename) of
                {ok, Input} ->
                    {State1, Data} = parse(State, Input),
                    parse_binary_impl(State1, Template#?MODULE{partials = [{P, Data} | Partials]});
                _ ->
                    error({?FILE_ERROR, Filename})
            end
    end;
parse_binary_impl(State, Input) ->
    {State1, Data} = parse(State, Input),
    parse_binary_impl(State1, #?MODULE{data = Data}).

%% @doc Analyze the syntax of the mustache.
-spec parse(state(), binary()) -> {#state{}, [tag()]}.
parse(State0, Bin) ->
    case parse1(State0, Bin, []) of
        {endtag, {_, OtherTag, _, _, _}} ->
            error({?PARSE_ERROR, {section_is_incorrect, OtherTag}});
        {#state{partials = Partials} = State, Tags} ->
            {State#state{partials = lists:usort(Partials), start = ?START_TAG, stop = ?STOP_TAG},
             lists:reverse(Tags)}
    end.

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
-spec parse1(state(), Input :: binary(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse1(#state{start = Start, stop = Stop} = State, Bin, Result) ->
    case binary:match(Bin, [Start, <<"\n">>]) of
        nomatch -> {State, ?ADD(Bin, Result)};
        {S, L}  ->
            Pos = S + L,
            B2  = binary:part(Bin, Pos, byte_size(Bin) - Pos),
            case binary:at(Bin, S) of
                $\n -> parse1(State, B2, ?ADD(binary:part(Bin, 0, Pos), Result)); % \n
                _   ->
                    StopSeparator = ?IIF(binary:first(B2) =:= ${, <<"}", Stop/binary>>, Stop),
                    parse2(State, [binary:part(Bin, 0, S) | binary:split(B2, StopSeparator)], Result)
            end
    end.

%% @doc Part of the `parse/1'
%%
%% 2nd Argument: [TagBinary(may exist unnecessary spaces to the end), RestBinary]
%% ATTENTION: The result is a list that is inverted.
-spec parse2(state(), iolist(), Result :: [tag()]) -> {state(), [tag()]} | endtag().
parse2(State, [B1, B2, B3], Result) ->
    case remove_space_from_head(B2) of
        <<T, Tag/binary>> when T =:= $&; T =:= ${ ->
            parse1(State, B3, [{'&', remove_spaces(Tag)} | ?ADD(B1, Result)]);
        <<T, Tag/binary>> when T =:= $#; T =:= $^ ->
            parse_loop(State, ?IIF(T =:= $#, '#', '^'), remove_spaces(Tag), B3, [B1 | Result]);
        <<"=", Tag0/binary>> ->
            Tag1 = remove_space_from_tail(Tag0),
            Size = byte_size(Tag1) - 1,
            case Size >= 0 andalso Tag1 of
                <<Tag2:Size/binary, "=">> -> parse_delimiter(State, Tag2, B3, [B1 | Result]);
                _                         -> error({?PARSE_ERROR, {unsupported_tag, <<"=", Tag0/binary>>}})
            end;
        <<"!", _/binary>> ->
            parse3(State, B3, [B1 | Result]);
        <<"/", Tag/binary>> ->
            {endtag, {State, remove_spaces(Tag), byte_size(B2) + 4, B3, ?ADD(B1, Result)}};
        <<">", Tag/binary>> ->
            parse_jump(State, remove_spaces(Tag), B3, [B1 | Result]);
        Tag ->
            parse1(State, B3, [{n, remove_spaces(Tag)} | ?ADD(B1, Result)])
    end;
parse2(_, _, _) ->
    error({?PARSE_ERROR, unclosed_tag}).

%% @doc Part of the `parse/1'
%%
%% it is end processing of tag that need to be considered the standalone.
-spec parse3(#state{}, binary(), [tag()]) -> {state(), [tag()]} | endtag().
parse3(State, Post, [Tag, Pre | Result]) when is_tuple(Tag) ->
    parse3_impl(State, Pre, Tag, Post, Result);
parse3(State, Post, [Tag | Result]) when is_tuple(Tag) ->
    parse3_impl(State, <<>>, Tag, Post, Result);
parse3(State, Post, [Pre | Result]) ->
    parse3_impl(State, Pre, false, Post, Result);
parse3(State, Post, Result) ->
    parse3_impl(State, <<>>, false, Post, Result).

%% @see parse3/3
-spec parse3_impl(#state{}, binary(), tag() | false, binary(), [tag()]) -> {state(), [tag()]} | endtag().
parse3_impl(State, Pre, Tag, Post, Result) ->
    case remove_space_if_standalone(Post) of
        {ok, NextPost} ->
            case remove_space_if_standalone(Pre) of
                {ok, _} -> parse1(State, NextPost, ?IIF(Tag =:= false, Result, [Tag | Result]));
                error   -> parse1(State, Post, ?IIF(Tag =:= false, ?ADD(Pre, Result), [Tag | ?ADD(Pre, Result)]))
            end;
        error ->
            parse1(State, Post, ?IIF(Tag =:= false, ?ADD(Pre, Result), [Tag | ?ADD(Pre, Result)]))
    end.

%% @doc if input is the standalone, remove unnecessary white space from the beginning. othewise, return error.
%%
%% standalone means only include whilte space or tab or new line.
-spec remove_space_if_standalone(binary()) -> {ok, binary()} | error.
remove_space_if_standalone(<<X:8, Rest/binary>>) when X =:= $ ; X =:= $\t ->
    remove_space_if_standalone(Rest);
remove_space_if_standalone(<<"\r\n", Rest/binary>>) ->
    {ok, Rest};
remove_space_if_standalone(<<"\n", Rest/binary>>) ->
    {ok, Rest};
remove_space_if_standalone(X = <<>>) ->
    {ok, X};
remove_space_if_standalone(_) ->
    error.

%% @doc Loop processing part of the `parse/1'
%%
%% `{{# Tag}}' or `{{^ Tag}}' corresponds to this.
-spec parse_loop(state(), '#' | '^', Tag :: binary(), Input :: binary(), Result :: [tag()]) -> [tag()] | endtag().
parse_loop(State0, Mark, Tag, Input, Result0) ->
    case parse3(State0, Input, []) of
        {endtag, {State, Tag, LastTagSize, Rest, Result1}} ->
            case Mark of
                '#' -> Source = binary:part(Input, 0, byte_size(Input) - byte_size(Rest) - LastTagSize),
                       parse3(State, Rest, [{'#', Tag, lists:reverse(Result1), Source} | Result0]);
                '^' -> parse3(State, Rest, [{'^', Tag, lists:reverse(Result1)} | Result0])
            end;
        {endtag, {_, OtherTag, _, _, _}} ->
            error({?PARSE_ERROR, {section_is_incorrect, OtherTag}});
        _ ->
            error({?PARSE_ERROR, {section_end_tag_not_found, <<"/", Tag/binary>>}})
    end.

%% @doc Endtag part of the `parse/1'
-spec parse_jump(state(), Tag :: binary(), NextBin :: binary(), Result :: [tag()]) -> [tag()] | endtag().
parse_jump(#state{partials = Partials} = State0, Tag, NextBin, Result) ->
    parse3(State0#state{partials = [Tag | Partials]}, NextBin, [{'>', Tag} | Result]).

%% @doc Update delimiter part of the `parse/1'
%%
%% ParseDelimiterBin :: e.g. `{{=%% %%=}}' -> `%% %%'
-spec parse_delimiter(state(), ParseDelimiterBin :: binary(), NextBin :: binary(), Result :: [tag()]) -> [tag()] | endtag().
parse_delimiter(State0, ParseDelimiterBin, NextBin, Result) ->
    case binary:match(ParseDelimiterBin, <<"=">>) of
        nomatch ->
            case [X || X <- binary:split(ParseDelimiterBin, <<" ">>, [global]), X =/= <<>>] of
                [Start, Stop] -> parse3(State0#state{start = Start, stop = Stop}, NextBin, Result);
                _             -> error({?PARSE_ERROR, delimiters_may_not_contain_whitespaces})
            end;
        _ ->
            error({?PARSE_ERROR, delimiters_may_not_contain_equals})
    end.

%% @doc Remove the spaces.
-spec remove_spaces(binary()) -> binary().
remove_spaces(Bin) ->
	<< <<X:8>> || <<X:8>> <= Bin, X =/= $ >>.

%% @doc Remove the space from the head.
-spec remove_space_from_head(binary()) -> binary().
remove_space_from_head(<<" ", Rest/binary>>) -> remove_space_from_head(Rest);
remove_space_from_head(Bin)                  -> Bin.

%% @doc Remove the space from the tail.
-spec remove_space_from_tail(binary()) -> binary().
remove_space_from_tail(<<>>) -> <<>>;
remove_space_from_tail(Bin) ->
    PosList = binary:matches(Bin, <<" ">>),
    LastPos = remove_space_from_tail_impl(lists:reverse(PosList), byte_size(Bin)),
    binary:part(Bin, 0, LastPos).

%% @see remove_space_from_tail/1
-spec remove_space_from_tail_impl([{non_neg_integer(), pos_integer()}], non_neg_integer()) -> non_neg_integer().
remove_space_from_tail_impl([{X, Y} | T], Size) when Size =:= X + Y ->
    remove_space_from_tail_impl(T, X);
remove_space_from_tail_impl(_, Size) ->
    Size.

%% @doc term to iodata
-spec to_iodata(number() | binary() | string() | atom()) -> iodata().
to_iodata(Integer) when is_integer(Integer) ->
    list_to_binary(integer_to_list(Integer));
to_iodata(Float) when is_float(Float) ->
    io_lib:format("~p", [Float]);
to_iodata(Atom) when is_atom(Atom) ->
    list_to_binary(atom_to_list(Atom));
to_iodata(X) ->
    X.

%% @doc string or binary to binary
-spec to_binary(binary() | string()) -> binary().
to_binary(Bin) when is_binary(Bin) ->
    Bin;
to_binary(Str) when is_list(Str) ->
    list_to_binary(Str).

%% @doc HTML Escape
-spec escape(iodata()) -> binary().
escape(IoData) ->
    Bin = iolist_to_binary(IoData),
    << <<(escape_char(X))/binary>> || <<X:8>> <= Bin >>.

%% @doc escape a character if needed.
-spec escape_char(0..16#FFFF) -> binary().
escape_char($<) -> <<"&lt;">>;
escape_char($>) -> <<"&gt;">>;
escape_char($&) -> <<"&amp;">>;
escape_char($") -> <<"&quot;">>;
escape_char(C)  -> <<C:8>>.

%% @doc convert to {@link data_key/0} from binary.
-spec convert_keytype(binary(), #?MODULE{}) -> data_key().
convert_keytype(KeyBin, #?MODULE{options = Options}) ->
    case proplists:get_value(key_type, Options, string) of
        atom ->
            try binary_to_existing_atom(KeyBin, utf8) of
                Atom -> Atom
            catch
                _:_ -> <<" ">> % It is not always present in data/0
            end;
        string -> binary_to_list(KeyBin);
        binary -> KeyBin
    end.

%% @doc fetch the value of the specified parent.child from {@link data/0}
%%
%% if key is ".", it means this.
-spec get_data_recursive(binary(), data(), Default :: term(), #?MODULE{}) -> term().
get_data_recursive(<<".">>, Data, _Default, _State) ->
	Data;
get_data_recursive(KeyBin, Data, Default, State) ->
	get_data_recursive_impl(binary:split(KeyBin, <<".">>, [global]), Data, Default, State).

%% @see get_data_recursive/4
-spec get_data_recursive_impl([BinKey :: binary()], data(), Default :: term(), #?MODULE{}) -> term().
get_data_recursive_impl([Key], Data, Default, State) ->
	get_data(convert_keytype(Key, State), Data, Default);
get_data_recursive_impl([Key | RestKey], Data, Default, State) ->
	ChildData = get_data(convert_keytype(Key, State), Data, Default),
    case ChildData =:= Default of
        true  -> ChildData;
        false -> get_data_recursive_impl(RestKey, ChildData, Default, State)
    end.

%% @doc fetch the value of the specified key from {@link data/0}
-spec get_data(data_key(), data(), Default :: term()) -> term().
-ifdef(namespaced_types).
get_data(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default);
get_data(Key, AssocList, Default) ->
    proplists:get_value(Key, AssocList, Default).
-else.
get_data(Key, AssocList, Default) ->
    proplists:get_value(Key, AssocList, Default).
-endif.

%% @doc check whether the type of {@link data/0}
%%
%% maybe: There is also the possibility of iolist
-spec check_data_type(data() | term()) -> boolean() | maybe.
-ifdef(namespaced_types).
check_data_type([])                               -> maybe;
check_data_type([Tuple | _]) when is_tuple(Tuple) -> true;
check_data_type(Map)                              -> is_map(Map).
-else.
check_data_type([])                               -> maybe;
check_data_type([Tuple | _]) when is_tuple(Tuple) -> true;
check_data_type(_)                                -> false.
-endif.
