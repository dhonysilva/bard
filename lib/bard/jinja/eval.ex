defmodule Bard.Jinja.Eval do
  @moduledoc """
  Renders a parsed template.

  Scoping follows Jinja: `for` bodies and macros get their own scope, so a
  `set` inside them does not leak out; `if` blocks share the enclosing scope.
  Lookups go from the innermost scope out to the globals.
  """

  alias Bard.Jinja.Error
  alias Bard.Jinja.Macro
  alias Bard.Jinja.Object
  alias Bard.Jinja.Value

  @doc false
  def render(nodes, globals) do
    {out, _scopes} = nodes(nodes, [%{}], globals)
    out
  end

  @doc false
  def call_macro(%Macro{} = macro, args, kwargs, globals) do
    if length(args) > length(macro.params) do
      raise Error.new(
              :too_many_args,
              "#{macro.name}() takes #{length(macro.params)} arguments, got #{length(args)}",
              macro.line
            )
    end

    known = MapSet.new(macro.params, &elem(&1, 0))

    case Enum.find(kwargs, fn {k, _} -> not MapSet.member?(known, k) end) do
      {k, _} ->
        raise Error.new(
                :unknown_kwarg,
                "#{macro.name}() got an unexpected argument `#{k}`",
                macro.line
              )

      nil ->
        :ok
    end

    kwargs = Map.new(kwargs)
    {positional, rest} = Enum.split(macro.params, length(args))
    scope = positional |> Enum.map(&elem(&1, 0)) |> Enum.zip(args) |> Map.new()

    scope =
      Enum.reduce(rest, scope, fn {name, default}, scope ->
        value =
          case {Map.fetch(kwargs, name), default} do
            {{:ok, value}, _} -> value
            {:error, nil} -> :undefined
            {:error, expr} -> eval(expr, [scope], globals)
          end

        Map.put(scope, name, value)
      end)

    try do
      {out, _} = nodes(macro.body, [scope], globals)
      IO.iodata_to_binary(out)
    catch
      {:jinja_return, value} -> value
    end
  end

  defp nodes(list, scopes, globals) do
    Enum.reduce(list, {[], scopes}, fn node, {out, scopes} ->
      try do
        {piece, scopes} = node(node, scopes, globals)
        {[out | piece], scopes}
      catch
        # Keep what this iteration printed before `break`/`continue`.
        {kind, piece} when kind in [:jinja_break, :jinja_continue] -> throw({kind, [out | piece]})
      end
    end)
  end

  defp node({:text, text}, scopes, _globals), do: {text, scopes}

  defp node({:output, expr, _line}, scopes, globals) do
    {expr |> eval(scopes, globals) |> Value.to_s(), scopes}
  end

  defp node({:if, branches, otherwise}, scopes, globals) do
    case Enum.find(branches, fn {condition, _} ->
           condition |> eval(scopes, globals) |> Value.truthy?()
         end) do
      {_, body} -> nodes(body, scopes, globals)
      nil -> nodes(otherwise, scopes, globals)
    end
  end

  defp node({:for, targets, iter, filter, body, otherwise, line}, scopes, globals) do
    items =
      iter
      |> eval(scopes, globals)
      |> Value.iterate(line)
      |> Enum.filter(fn item ->
        filter == nil or
          filter |> eval([bind(targets, item, line) | scopes], globals) |> Value.truthy?()
      end)

    if items == [] do
      nodes(otherwise, scopes, globals)
    else
      total = length(items)

      out =
        items
        |> Enum.with_index()
        |> Enum.reduce_while([], fn {item, i}, out ->
          loop = %Object{
            str: "<loop>",
            attrs: %{
              "index" => i + 1,
              "index0" => i,
              "revindex" => total - i,
              "revindex0" => total - i - 1,
              "first" => i == 0,
              "last" => i == total - 1,
              "length" => total,
              "previtem" => if(i > 0, do: Enum.at(items, i - 1), else: :undefined),
              "nextitem" => Enum.at(items, i + 1, :undefined)
            }
          }

          scope = Map.put(bind(targets, item, line), "loop", loop)

          try do
            {piece, _} = nodes(body, [scope | scopes], globals)
            {:cont, [out | piece]}
          catch
            {:jinja_break, piece} -> {:halt, [out | piece]}
            {:jinja_continue, piece} -> {:cont, [out | piece]}
          end
        end)

      {out, scopes}
    end
  end

  defp node({:set, targets, expr, line}, [scope | outer], globals) do
    value = eval(expr, [scope | outer], globals)
    {[], [Map.merge(scope, bind(targets, value, line)) | outer]}
  end

  defp node({:set_block, name, body}, [scope | outer] = scopes, globals) do
    {out, _} = nodes(body, scopes, globals)
    {[], [Map.put(scope, name, IO.iodata_to_binary(out)) | outer]}
  end

  defp node({:macro, name, params, body, line}, [scope | outer], _globals) do
    {[],
     [Map.put(scope, name, %Macro{name: name, params: params, body: body, line: line}) | outer]}
  end

  defp node({:do, expr, _line}, scopes, globals) do
    eval(expr, scopes, globals)
    {[], scopes}
  end

  # break/continue unwind to the enclosing loop, carrying the output printed
  # so far in this iteration (see nodes/3).
  defp node({:break, _line}, _scopes, _globals), do: throw({:jinja_break, []})
  defp node({:continue, _line}, _scopes, _globals), do: throw({:jinja_continue, []})

  defp bind([name], value, _line), do: %{name => value}

  defp bind(names, value, _line) when is_list(value) and length(names) == length(value),
    do: names |> Enum.zip(value) |> Map.new()

  defp bind(names, _value, line),
    do: raise(Error.new(:unpack, "cannot unpack into #{length(names)} names", line))

  # -- expressions -----------------------------------------------------------------

  defp eval({:lit, value}, _scopes, _globals), do: value

  defp eval({:name, name, _line}, scopes, globals) do
    case Enum.find_value(scopes, fn scope -> Map.fetch(scope, name) |> found() end) do
      {:found, value} -> value
      nil -> Map.get(globals, name, :undefined)
    end
  end

  defp eval({:list, items}, scopes, globals), do: Enum.map(items, &eval(&1, scopes, globals))

  defp eval({:dict, pairs}, scopes, globals),
    do: Map.new(pairs, fn {k, v} -> {eval(k, scopes, globals), eval(v, scopes, globals)} end)

  defp eval({:getattr, expr, name, line}, scopes, globals),
    do: expr |> eval(scopes, globals) |> Value.getattr(name, line)

  defp eval({:getitem, expr, index, line}, scopes, globals),
    do: expr |> eval(scopes, globals) |> Value.getitem(eval(index, scopes, globals), line)

  defp eval({:call, target, args, kwargs, line}, scopes, globals) do
    callee = eval(target, scopes, globals)
    args = Enum.map(args, &eval(&1, scopes, globals))
    kwargs = Enum.map(kwargs, fn {k, v} -> {k, eval(v, scopes, globals)} end)
    call(callee, args, kwargs, target, line, globals)
  end

  defp eval({:filter, expr, name, args, kwargs, line}, scopes, globals) do
    value = eval(expr, scopes, globals)
    args = Enum.map(args, &eval(&1, scopes, globals))
    args = args ++ Enum.map(kwargs, fn {_k, v} -> eval(v, scopes, globals) end)
    Value.filter(name, value, args, line)
  end

  defp eval({:test, expr, name, args, line}, scopes, globals) do
    value = eval(expr, scopes, globals)
    args = Enum.map(args, &eval(&1, scopes, globals))

    case Value.test(name, value, args) do
      {:unsupported, name} ->
        raise Error.new({:unsupported_test, name}, "the `#{name}` test is not supported", line)

      result ->
        result
    end
  end

  defp eval({:not, expr}, scopes, globals), do: not Value.truthy?(eval(expr, scopes, globals))

  defp eval({:neg, expr}, scopes, globals) do
    case eval(expr, scopes, globals) do
      n when is_number(n) -> -n
      other -> raise Error.new(:bad_operand, "cannot negate #{Value.type_name(other)}", nil)
    end
  end

  # `and`/`or` return an operand, like Python.
  defp eval({:and, a, b}, scopes, globals) do
    left = eval(a, scopes, globals)
    if Value.truthy?(left), do: eval(b, scopes, globals), else: left
  end

  defp eval({:or, a, b}, scopes, globals) do
    left = eval(a, scopes, globals)
    if Value.truthy?(left), do: left, else: eval(b, scopes, globals)
  end

  defp eval({:cond, test, then, otherwise}, scopes, globals) do
    if Value.truthy?(eval(test, scopes, globals)),
      do: eval(then, scopes, globals),
      else: eval(otherwise, scopes, globals)
  end

  defp eval({:cmp, op, a, b, line}, scopes, globals) do
    left = eval(a, scopes, globals)
    right = eval(b, scopes, globals)

    case op do
      :eq -> Value.equal?(left, right)
      :ne -> not Value.equal?(left, right)
      :in -> Value.contains?(right, left, line)
      :not_in -> not Value.contains?(right, left, line)
      op -> Value.compare(op, left, right, line)
    end
  end

  defp eval({:binop, op, a, b, line}, scopes, globals),
    do: Value.binop(op, eval(a, scopes, globals), eval(b, scopes, globals), line)

  defp found({:ok, value}), do: {:found, value}
  defp found(:error), do: nil

  defp call(%Macro{} = macro, args, kwargs, _target, _line, globals),
    do: call_macro(macro, args, kwargs, globals)

  defp call(fun, args, kwargs, _target, line, _globals) when is_function(fun, 2),
    do: call_elixir(fun, args, kwargs, line)

  defp call(%Object{call: fun}, args, kwargs, _target, line, _globals) when is_function(fun, 2),
    do: call_elixir(fun, args, kwargs, line)

  defp call({:method, value, name}, args, _kwargs, _target, line, _globals),
    do: Value.call_method(value, name, args, line)

  defp call(:undefined, _args, _kwargs, target, line, _globals) do
    raise Error.new(
            {:undefined_function, callee_name(target)},
            "`#{callee_name(target)}` is not defined",
            line
          )
  end

  defp call(value, _args, _kwargs, target, line, _globals),
    do:
      raise(
        Error.new(
          :not_callable,
          "`#{callee_name(target)}` (#{Value.type_name(value)}) is not callable",
          line
        )
      )

  # Functions from Elixir (dbt's `ref`, `config`, ...) raise errors without a
  # line; they get the line of the call.
  defp call_elixir(fun, args, kwargs, line) do
    fun.(args, Map.new(kwargs))
  rescue
    error in Error -> reraise %{error | line: error.line || line}, __STACKTRACE__
  end

  defp callee_name({:name, name, _}), do: name
  defp callee_name({:getattr, expr, name, _}), do: callee_name(expr) <> "." <> name
  defp callee_name(_), do: "expression"
end
