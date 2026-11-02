defmodule Bard.Jinja.Parser do
  @moduledoc """
  Turns lexer tokens into an AST.

  Statements:

      {:text, binary}
      {:output, expr, line}
      {:if, [{cond, body}], else_body}
      {:for, targets, iterable, filter, body, else_body, line}
      {:set, targets, expr, line}
      {:set_block, name, body}
      {:macro, name, [{param, default_expr | nil}], body, line}
      {:do, expr, line}
      {:break, line} | {:continue, line}

  Expressions follow Jinja's precedence, lowest first: conditional
  (`a if c else b`), `or`, `and`, `not`, comparisons and `in`, `+ -`, `~`,
  `* / // %`, `**`, unary `- +`, then filters (`|`) and tests (`is`), then
  attribute, item and call postfixes.
  """

  alias Bard.Jinja.Error

  @spec parse(list()) :: {:ok, list()} | {:error, Error.t()}
  def parse(tokens) do
    case body(tokens, []) do
      {nodes, [], nil} ->
        {:ok, nodes}

      {_nodes, _rest, {tag, line}} ->
        {:error, Error.new(:unexpected_tag, "unexpected {% #{tag} %}", line)}
    end
  rescue
    error in Error -> {:error, error}
  end

  # Parses until one of `stop` tags; returns {nodes, rest_after_stop_tag, {stop_tag_source, line} | nil}.
  defp body([], _stop), do: {[], [], nil}

  defp body([{:text, text} | rest], stop) do
    {nodes, rest, ended} = body(rest, stop)
    {[{:text, text} | nodes], rest, ended}
  end

  defp body([{:output, src, line} | rest], stop) do
    expr = expression(src, line)
    {nodes, rest, ended} = body(rest, stop)
    {[{:output, expr, line} | nodes], rest, ended}
  end

  defp body([{:tag, src, line} | rest], stop) do
    name = tag_name(src)

    if name in stop do
      {[], rest, {src, line}}
    else
      {node, rest} = statement(name, src, line, rest)
      {nodes, rest, ended} = body(rest, stop)
      {[node | nodes], rest, ended}
    end
  end

  defp tag_name(src), do: src |> String.split(~r/[\s(]/, parts: 2) |> hd()

  defp statement("if", src, line, rest), do: if_chain(args_of(src, "if"), line, rest, [])

  defp statement("for", src, line, rest) do
    {targets, iter_src} = split_for(args_of(src, "for"), line)
    {iter, filter} = split_for_filter(iter_src, line)
    {body_nodes, rest, ended} = body(rest, ["else", "endfor"])
    ended || unclosed!("for", line)

    {else_nodes, rest} =
      case ended do
        {"else", _} ->
          {nodes, rest, ended} = body(rest, ["endfor"])
          ended || unclosed!("for", line)
          {nodes, rest}

        _ ->
          {[], rest}
      end

    {{:for, targets, iter, filter, body_nodes, else_nodes, line}, rest}
  end

  defp statement("set", src, line, rest) do
    args = args_of(src, "set")

    case Regex.run(~r/\A([A-Za-z_][\w\s,]*?)\s*=(?!=)\s*(.+)\z/s, args) do
      [_, targets, expr_src] ->
        targets = targets |> String.split(",") |> Enum.map(&String.trim/1)
        {{:set, targets, expression(expr_src, line), line}, rest}

      nil ->
        name = String.trim(args)
        valid_name!(name, line)
        {nodes, rest, ended} = body(rest, ["endset"])
        ended || unclosed!("set", line)
        {{:set_block, name, nodes}, rest}
    end
  end

  defp statement("macro", src, line, rest) do
    {name, params} = macro_signature(args_of(src, "macro"), line)
    {nodes, rest, ended} = body(rest, ["endmacro"])
    ended || unclosed!("macro", line)
    {{:macro, name, params, nodes, line}, rest}
  end

  defp statement("do", src, line, rest),
    do: {{:do, expression(args_of(src, "do"), line), line}, rest}

  defp statement("break", _src, line, rest), do: {{:break, line}, rest}
  defp statement("continue", _src, line, rest), do: {{:continue, line}, rest}

  defp statement(name, _src, line, _rest) do
    raise Error.new({:unsupported_tag, name}, "the {% #{name} %} tag is not supported", line)
  end

  defp if_chain(cond_src, line, rest, branches) do
    condition = expression(cond_src, line)
    {nodes, rest, ended} = body(rest, ["elif", "else", "endif"])
    branches = [{condition, nodes} | branches]

    case ended do
      {"endif" <> _, _} ->
        {{:if, Enum.reverse(branches), []}, rest}

      {"else" <> _, _} ->
        {else_nodes, rest, ended} = body(rest, ["endif"])
        ended || unclosed!("if", line)
        {{:if, Enum.reverse(branches), else_nodes}, rest}

      {"elif" <> _ = src, elif_line} ->
        if_chain(args_of(src, "elif"), elif_line, rest, branches)

      nil ->
        unclosed!("if", line)
    end
  end

  defp args_of(src, name), do: src |> String.replace_prefix(name, "") |> String.trim()

  defp split_for(args, line) do
    case Regex.run(~r/\A(.+?)\s+in\s+(.+)\z/s, args) do
      [_, targets, iter] ->
        targets =
          targets
          |> String.trim_leading("(")
          |> String.trim_trailing(")")
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        Enum.each(targets, &valid_name!(&1, line))
        {targets, iter}

      nil ->
        raise Error.new(:bad_for, "expected `for x in items`", line)
    end
  end

  # `for x in items if cond`: the trailing `if` filters items. Only split on an
  # `if` that is not part of a conditional expression (`a if b else c`).
  defp split_for_filter(src, line) do
    tokens = tokenize(src, line)

    case Enum.find_index(tokens, &match?({:name, "if", _}, &1)) do
      nil ->
        {parse_tokens(tokens, line), nil}

      i ->
        {iter, [_if | cond]} = Enum.split(tokens, i)

        if Enum.any?(cond, &match?({:name, "else", _}, &1)),
          do: {parse_tokens(tokens, line), nil},
          else: {parse_tokens(iter, line), parse_tokens(cond, line)}
    end
  end

  defp macro_signature(args, line) do
    case Regex.run(~r/\A([A-Za-z_]\w*)\s*\((.*)\)\s*\z/s, args) do
      [_, name, params_src] ->
        params =
          params_src
          |> split_top_level(",")
          |> Enum.reject(&(String.trim(&1) == ""))
          |> Enum.map(fn param ->
            case String.split(param, "=", parts: 2) do
              [name] -> {valid_name!(String.trim(name), line), nil}
              [name, default] -> {valid_name!(String.trim(name), line), expression(default, line)}
            end
          end)

        {name, params}

      nil ->
        raise Error.new(:bad_macro, "expected `macro name(params)`", line)
    end
  end

  defp split_top_level(src, sep) do
    {parts, current, _depth, _quote} =
      src
      |> String.graphemes()
      |> Enum.reduce({[], "", 0, nil}, fn
        c, {parts, cur, d, nil} when c in ["'", "\""] -> {parts, cur <> c, d, c}
        c, {parts, cur, d, q} when c == q -> {parts, cur <> c, d, nil}
        c, {parts, cur, d, q} when q != nil -> {parts, cur <> c, d, q}
        c, {parts, cur, d, nil} when c in ["(", "[", "{"] -> {parts, cur <> c, d + 1, nil}
        c, {parts, cur, d, nil} when c in [")", "]", "}"] -> {parts, cur <> c, d - 1, nil}
        ^sep, {parts, cur, 0, nil} -> {[cur | parts], "", 0, nil}
        c, {parts, cur, d, nil} -> {parts, cur <> c, d, nil}
      end)

    Enum.reverse([current | parts])
  end

  defp valid_name!(name, line) do
    if Regex.match?(~r/\A[A-Za-z_]\w*\z/, name),
      do: name,
      else: raise(Error.new(:bad_name, "invalid name `#{name}`", line))
  end

  defp unclosed!(tag, line),
    do: raise(Error.new(:unclosed_block, "{% #{tag} %} is never closed", line))

  @doc false
  def expression(src, line), do: src |> tokenize(line) |> parse_tokens(line)

  defp parse_tokens(tokens, line) do
    case conditional(tokens) do
      {expr, []} ->
        expr

      {_expr, [token | _]} ->
        raise Error.new(
                :unexpected_token,
                "unexpected `#{token_text(token)}`",
                token_line(token, line)
              )
    end
  end

  @operators ~w(** // == != <= >= + - * / % ~ < > = | . , : ( \) [ ] { })

  defp tokenize(src, line), do: lex(src, line, [])

  defp lex("", _line, acc), do: Enum.reverse(acc)

  defp lex(<<c, rest::binary>>, line, acc) when c in [?\s, ?\t, ?\r], do: lex(rest, line, acc)
  defp lex(<<?\n, rest::binary>>, line, acc), do: lex(rest, line + 1, acc)

  defp lex(<<q, rest::binary>>, line, acc) when q in [?', ?"] do
    {string, rest, newlines} = read_string(rest, q, [], 0, line)
    lex(rest, line + newlines, [{:string, string, line} | acc])
  end

  defp lex(<<c, _::binary>> = src, line, acc) when c in ?0..?9 do
    [number | _] = Regex.run(~r/\A\d+(\.\d+)?([eE][+-]?\d+)?/, src)
    rest = binary_part(src, byte_size(number), byte_size(src) - byte_size(number))

    value =
      if String.contains?(number, [".", "e", "E"]),
        do: number |> String.replace(~r/\A(\d+)([eE])/, "\\1.0\\2") |> String.to_float(),
        else: String.to_integer(number)

    lex(rest, line, [{:number, value, line} | acc])
  end

  defp lex(<<c, _::binary>> = src, line, acc) when c in ?a..?z or c in ?A..?Z or c == ?_ do
    [name] = Regex.run(~r/\A[A-Za-z_]\w*/, src)
    rest = binary_part(src, byte_size(name), byte_size(src) - byte_size(name))
    lex(rest, line, [{:name, name, line} | acc])
  end

  defp lex(src, line, acc) do
    case Enum.find(@operators, &String.starts_with?(src, &1)) do
      nil ->
        raise Error.new(:bad_character, "unexpected character `#{String.first(src)}`", line)

      op ->
        rest = binary_part(src, byte_size(op), byte_size(src) - byte_size(op))
        lex(rest, line, [{:op, op, line} | acc])
    end
  end

  defp read_string("", _q, _acc, _n, line),
    do: raise(Error.new(:unclosed_string, "unclosed string", line))

  defp read_string(<<"\\n", rest::binary>>, q, acc, n, l),
    do: read_string(rest, q, ["\n" | acc], n, l)

  defp read_string(<<"\\t", rest::binary>>, q, acc, n, l),
    do: read_string(rest, q, ["\t" | acc], n, l)

  defp read_string(<<"\\", c::utf8, rest::binary>>, q, acc, n, l),
    do: read_string(rest, q, [<<c::utf8>> | acc], n, l)

  defp read_string(<<q, rest::binary>>, q, acc, n, _l),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest, n}

  defp read_string(<<?\n, rest::binary>>, q, acc, n, l),
    do: read_string(rest, q, ["\n" | acc], n + 1, l)

  defp read_string(<<c::utf8, rest::binary>>, q, acc, n, l),
    do: read_string(rest, q, [<<c::utf8>> | acc], n, l)

  defp token_text({_, v, _}) when is_binary(v), do: v
  defp token_text({_, v, _}), do: to_string(v)
  defp token_line({_, _, l}, _), do: l

  # conditional: or_expr ('if' or_expr ('else' conditional)?)?
  defp conditional(tokens) do
    {expr, rest} = or_expr(tokens)

    case rest do
      [{:name, "if", _} | rest] ->
        {test, rest} = or_expr(rest)

        case rest do
          [{:name, "else", _} | rest] ->
            {otherwise, rest} = conditional(rest)
            {{:cond, test, expr, otherwise}, rest}

          _ ->
            {{:cond, test, expr, {:lit, :undefined}}, rest}
        end

      _ ->
        {expr, rest}
    end
  end

  defp or_expr(tokens) do
    {left, rest} = and_expr(tokens)
    or_tail(left, rest)
  end

  defp or_tail(left, [{:name, "or", _} | rest]) do
    {right, rest} = and_expr(rest)
    or_tail({:or, left, right}, rest)
  end

  defp or_tail(left, rest), do: {left, rest}

  defp and_expr(tokens) do
    {left, rest} = not_expr(tokens)
    and_tail(left, rest)
  end

  defp and_tail(left, [{:name, "and", _} | rest]) do
    {right, rest} = not_expr(rest)
    and_tail({:and, left, right}, rest)
  end

  defp and_tail(left, rest), do: {left, rest}

  defp not_expr([{:name, "not", _} | rest]) do
    {expr, rest} = not_expr(rest)
    {{:not, expr}, rest}
  end

  defp not_expr(tokens), do: compare(tokens)

  @comparisons %{"==" => :eq, "!=" => :ne, "<" => :lt, ">" => :gt, "<=" => :le, ">=" => :ge}

  defp compare(tokens) do
    {left, rest} = math1(tokens)
    compare_tail(left, rest)
  end

  defp compare_tail(left, [{:op, op, line} | rest]) when is_map_key(@comparisons, op) do
    {right, rest} = math1(rest)
    compare_tail({:cmp, Map.fetch!(@comparisons, op), left, right, line}, rest)
  end

  defp compare_tail(left, [{:name, "in", line} | rest]) do
    {right, rest} = math1(rest)
    compare_tail({:cmp, :in, left, right, line}, rest)
  end

  defp compare_tail(left, [{:name, "not", line}, {:name, "in", _} | rest]) do
    {right, rest} = math1(rest)
    compare_tail({:cmp, :not_in, left, right, line}, rest)
  end

  defp compare_tail(left, rest), do: {left, rest}

  defp math1(tokens) do
    {left, rest} = concat(tokens)
    math1_tail(left, rest)
  end

  defp math1_tail(left, [{:op, op, line} | rest]) when op in ["+", "-"] do
    {right, rest} = concat(rest)
    math1_tail({:binop, op, left, right, line}, rest)
  end

  defp math1_tail(left, rest), do: {left, rest}

  defp concat(tokens) do
    {left, rest} = math2(tokens)
    concat_tail(left, rest)
  end

  defp concat_tail(left, [{:op, "~", line} | rest]) do
    {right, rest} = math2(rest)
    concat_tail({:binop, "~", left, right, line}, rest)
  end

  defp concat_tail(left, rest), do: {left, rest}

  defp math2(tokens) do
    {left, rest} = pow(tokens)
    math2_tail(left, rest)
  end

  defp math2_tail(left, [{:op, op, line} | rest]) when op in ["*", "/", "//", "%"] do
    {right, rest} = pow(rest)
    math2_tail({:binop, op, left, right, line}, rest)
  end

  defp math2_tail(left, rest), do: {left, rest}

  defp pow(tokens) do
    {left, rest} = unary(tokens)

    case rest do
      [{:op, "**", line} | rest] ->
        {right, rest} = unary(rest)
        {{:binop, "**", left, right, line}, rest}

      _ ->
        {left, rest}
    end
  end

  defp unary([{:op, "-", _} | rest]) do
    {expr, rest} = unary(rest)
    {{:neg, expr}, rest}
  end

  defp unary([{:op, "+", _} | rest]), do: unary(rest)

  defp unary(tokens) do
    {expr, rest} = primary(tokens)
    {expr, rest} = postfix(expr, rest)
    filters(expr, rest)
  end

  # filters: expr ('|' name args? | 'is' 'not'? test args?)*
  defp filters(expr, [{:op, "|", _}, {:name, name, line} | rest]) do
    {args, kwargs, rest} = maybe_call_args(rest)
    {expr, rest} = postfix({:filter, expr, name, args, kwargs, line}, rest)
    filters(expr, rest)
  end

  defp filters(expr, [{:name, "is", _}, {:name, "not", _}, {:name, name, line} | rest]) do
    {args, rest} = test_args(rest)
    filters({:not, {:test, expr, name, args, line}}, rest)
  end

  defp filters(expr, [{:name, "is", _}, {:name, name, line} | rest]) do
    {args, rest} = test_args(rest)
    filters({:test, expr, name, args, line}, rest)
  end

  defp filters(expr, rest), do: {expr, rest}

  defp test_args([{:op, "(", _} | _] = tokens) do
    {args, _kwargs, rest} = maybe_call_args(tokens)
    {args, rest}
  end

  # `x is sameas none` style single argument without parentheses.
  defp test_args([{kind, _, _} | _] = tokens) when kind in [:string, :number] do
    {arg, rest} = primary(tokens)
    {[arg], rest}
  end

  defp test_args(tokens), do: {[], tokens}

  defp maybe_call_args([{:op, "(", _} | rest]), do: call_args(rest, [], [])
  defp maybe_call_args(rest), do: {[], [], rest}

  defp call_args([{:op, ")", _} | rest], args, kwargs),
    do: {Enum.reverse(args), Enum.reverse(kwargs), rest}

  defp call_args([{:name, key, _}, {:op, "=", _} | rest], args, kwargs) do
    {value, rest} = conditional(rest)
    call_args_next(rest, args, [{key, value} | kwargs])
  end

  defp call_args(tokens, args, kwargs) do
    {value, rest} = conditional(tokens)
    call_args_next(rest, [value | args], kwargs)
  end

  defp call_args_next([{:op, ",", _} | rest], args, kwargs), do: call_args(rest, args, kwargs)

  defp call_args_next([{:op, ")", _} | rest], args, kwargs),
    do: {Enum.reverse(args), Enum.reverse(kwargs), rest}

  defp call_args_next([token | _], _, _),
    do:
      raise(
        Error.new(
          :bad_call,
          "expected `,` or `)`, got `#{token_text(token)}`",
          token_line(token, nil)
        )
      )

  defp call_args_next([], _, _), do: raise(Error.new(:bad_call, "unclosed call", nil))

  defp postfix(expr, [{:op, ".", _}, {:name, name, line} | rest]),
    do: postfix({:getattr, expr, name, line}, rest)

  defp postfix(expr, [{:op, "[", line} | rest]) do
    {index, rest} = conditional(rest)

    case rest do
      [{:op, "]", _} | rest] -> postfix({:getitem, expr, index, line}, rest)
      _ -> raise Error.new(:bad_subscript, "expected `]`", line)
    end
  end

  defp postfix(expr, [{:op, "(", line} | _] = tokens) do
    {args, kwargs, rest} = maybe_call_args(tokens)
    postfix({:call, expr, args, kwargs, line}, rest)
  end

  defp postfix(expr, rest), do: {expr, rest}

  @literals %{
    "true" => true,
    "True" => true,
    "false" => false,
    "False" => false,
    "none" => nil,
    "None" => nil
  }

  defp primary([{:string, s, _} | rest]), do: string_concat(s, rest)
  defp primary([{:number, n, _} | rest]), do: {{:lit, n}, rest}

  defp primary([{:name, name, line} | rest]) do
    case Map.fetch(@literals, name) do
      {:ok, value} -> {{:lit, value}, rest}
      :error -> {{:name, name, line}, rest}
    end
  end

  defp primary([{:op, "(", line} | rest]) do
    case rest do
      [{:op, ")", _} | rest] ->
        {{:list, []}, rest}

      _ ->
        {expr, rest} = conditional(rest)
        tuple_or_group(expr, rest, line)
    end
  end

  defp primary([{:op, "[", _} | rest]) do
    {items, rest} = sequence(rest, "]", [])
    {{:list, items}, rest}
  end

  defp primary([{:op, "{", _} | rest]), do: dict(rest, [])

  defp primary([token | _]),
    do:
      raise(
        Error.new(:unexpected_token, "unexpected `#{token_text(token)}`", token_line(token, nil))
      )

  defp primary([]), do: raise(Error.new(:unexpected_end, "expression ends too early", nil))

  # Adjacent string literals concatenate, as in Python.
  defp string_concat(s, [{:string, more, _} | rest]), do: string_concat(s <> more, rest)
  defp string_concat(s, rest), do: {{:lit, s}, rest}

  defp tuple_or_group(expr, [{:op, ")", _} | rest], _line), do: {expr, rest}

  defp tuple_or_group(expr, [{:op, ",", _} | rest], _line) do
    {items, rest} = sequence(rest, ")", [expr])
    {{:list, items}, rest}
  end

  defp tuple_or_group(_expr, _rest, line), do: raise(Error.new(:bad_group, "expected `)`", line))

  defp sequence([{:op, close, _} | rest], close, acc), do: {Enum.reverse(acc), rest}

  defp sequence(tokens, close, acc) do
    {item, rest} = conditional(tokens)

    case rest do
      [{:op, ",", _} | rest] -> sequence(rest, close, [item | acc])
      [{:op, ^close, _} | rest] -> {Enum.reverse([item | acc]), rest}
      _ -> raise Error.new(:bad_sequence, "expected `,` or `#{close}`", nil)
    end
  end

  defp dict([{:op, "}", _} | rest], acc), do: {{:dict, Enum.reverse(acc)}, rest}

  defp dict(tokens, acc) do
    {key, rest} = conditional(tokens)

    case rest do
      [{:op, ":", _} | rest] ->
        {value, rest} = conditional(rest)

        case rest do
          [{:op, ",", _} | rest] -> dict(rest, [{key, value} | acc])
          [{:op, "}", _} | rest] -> {{:dict, Enum.reverse([{key, value} | acc])}, rest}
          _ -> raise Error.new(:bad_dict, "expected `,` or `}`", nil)
        end

      _ ->
        raise Error.new(:bad_dict, "expected `:` in dict", nil)
    end
  end
end
