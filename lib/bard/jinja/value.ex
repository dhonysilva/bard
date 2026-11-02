defmodule Bard.Jinja.Value do
  @moduledoc """
  Python semantics for template values: how they print, which are truthy,
  and the filters, tests and methods templates may use.

  Values are Elixir terms: binaries, integers, floats, booleans, `nil`
  (Python's `None`), `:undefined`, lists, maps with string keys,
  `%Bard.Jinja.Object{}`, `%Bard.Jinja.Macro{}` and 2-arity functions
  `fn args, kwargs -> value end`.
  """

  alias Bard.Jinja.Error
  alias Bard.Jinja.Macro
  alias Bard.Jinja.Object

  @doc "Python's `str()`."
  @spec to_s(term()) :: String.t()
  def to_s(value) when is_binary(value), do: value
  def to_s(:undefined), do: ""
  def to_s(nil), do: "None"
  def to_s(true), do: "True"
  def to_s(false), do: "False"
  def to_s(value) when is_integer(value), do: Integer.to_string(value)
  def to_s(value) when is_float(value), do: float_to_s(value)
  def to_s(%Object{str: str}), do: str
  def to_s(%Macro{name: name}), do: "<Macro #{name}>"
  def to_s(value) when is_list(value) or is_map(value), do: repr(value)
  def to_s(value) when is_function(value), do: "<function>"

  @doc "Python's `repr()`."
  @spec repr(term()) :: String.t()
  def repr(value) when is_binary(value) do
    if String.contains?(value, "'") and not String.contains?(value, "\""),
      do: "\"" <> value <> "\"",
      else: "'" <> (value |> String.replace("\\", "\\\\") |> String.replace("'", "\\'")) <> "'"
  end

  def repr(value) when is_list(value), do: "[" <> Enum.map_join(value, ", ", &repr/1) <> "]"

  def repr(%Object{} = object), do: to_s(object)

  def repr(value) when is_map(value) and not is_struct(value),
    do: "{" <> Enum.map_join(value, ", ", fn {k, v} -> repr(k) <> ": " <> repr(v) end) <> "}"

  def repr(value), do: to_s(value)

  defp float_to_s(value) do
    text = :erlang.float_to_binary(value, [:short])

    cond do
      String.contains?(text, "e") -> text
      String.contains?(text, ".") -> text
      true -> text <> ".0"
    end
  end

  @doc "Python truthiness."
  @spec truthy?(term()) :: boolean()
  def truthy?(value) when value in [nil, false, :undefined, "", 0, [], 0.0], do: false

  def truthy?(value) when is_map(value) and not is_struct(value) and map_size(value) == 0,
    do: false

  def truthy?(_), do: true

  def equal?(a, b) when is_number(a) and is_number(b), do: a == b
  def equal?(%Object{str: a}, %Object{str: b}), do: a == b
  def equal?(a, b), do: a === b

  def contains?(container, item, line) do
    cond do
      is_binary(container) and is_binary(item) -> String.contains?(container, item)
      is_list(container) -> Enum.any?(container, &equal?(&1, item))
      is_map(container) and not is_struct(container) -> Map.has_key?(container, item)
      container == :undefined -> false
      true -> raise Error.new(:bad_in, "`in` is not supported for #{type_name(container)}", line)
    end
  end

  def compare(op, a, b, line)
      when (is_number(a) and is_number(b)) or (is_binary(a) and is_binary(b)) do
    case op do
      :lt -> a < b
      :gt -> a > b
      :le -> a <= b
      :ge -> a >= b
    end
  rescue
    _ -> raise Error.new(:bad_compare, "cannot compare #{type_name(a)} and #{type_name(b)}", line)
  end

  def compare(_op, a, b, line),
    do: raise(Error.new(:bad_compare, "cannot compare #{type_name(a)} and #{type_name(b)}", line))

  def binop("~", a, b, _line), do: to_s(a) <> to_s(b)
  def binop("+", a, b, _line) when is_number(a) and is_number(b), do: a + b
  def binop("+", a, b, _line) when is_binary(a) and is_binary(b), do: a <> b
  def binop("+", a, b, _line) when is_list(a) and is_list(b), do: a ++ b
  def binop("-", a, b, _line) when is_number(a) and is_number(b), do: a - b
  def binop("*", a, b, _line) when is_number(a) and is_number(b), do: a * b

  def binop("*", a, b, _line) when is_binary(a) and is_integer(b),
    do: String.duplicate(a, max(b, 0))

  def binop("/", _a, b, line) when b == 0,
    do: raise(Error.new(:division_by_zero, "division by zero", line))

  def binop("/", a, b, _line) when is_number(a) and is_number(b), do: a / b

  def binop("//", _a, b, line) when b == 0,
    do: raise(Error.new(:division_by_zero, "division by zero", line))

  def binop("//", a, b, _line) when is_integer(a) and is_integer(b), do: Integer.floor_div(a, b)
  def binop("//", a, b, _line) when is_number(a) and is_number(b), do: Float.floor(a / b)

  def binop("%", a, b, _line) when is_integer(a) and is_integer(b) and b != 0,
    do: Integer.mod(a, b)

  def binop("**", a, b, _line) when is_integer(a) and is_integer(b) and b >= 0,
    do: Integer.pow(a, b)

  def binop("**", a, b, _line) when is_number(a) and is_number(b), do: :math.pow(a, b)

  def binop(op, a, b, line),
    do:
      raise(
        Error.new(
          :bad_operands,
          "unsupported operands for #{op}: #{type_name(a)} and #{type_name(b)}",
          line
        )
      )

  def getattr(%Object{attrs: attrs}, name, _line), do: Map.get(attrs, name, :undefined)

  def getattr(map, name, _line) when is_map(map) and not is_struct(map) do
    case Map.fetch(map, name) do
      {:ok, value} -> value
      :error -> if name in ~w(get items keys values), do: {:method, map, name}, else: :undefined
    end
  end

  def getattr(value, name, _line) when is_binary(value) or is_list(value),
    do: {:method, value, name}

  def getattr(:undefined, _name, _line), do: :undefined

  def getattr(value, name, line),
    do: raise(Error.new(:bad_attribute, "#{type_name(value)} has no attribute `#{name}`", line))

  def getitem(list, index, _line) when is_list(list) and is_integer(index),
    do: Enum.at(list, index, :undefined)

  def getitem(binary, index, _line) when is_binary(binary) and is_integer(index),
    do: String.at(binary, index) || :undefined

  def getitem(%Object{} = object, key, line) when is_binary(key), do: getattr(object, key, line)
  def getitem(map, key, _line) when is_map(map), do: Map.get(map, key, :undefined)
  def getitem(:undefined, _key, _line), do: :undefined

  def getitem(value, _key, line),
    do: raise(Error.new(:bad_subscript, "#{type_name(value)} is not subscriptable", line))

  def call_method(s, "lower", [], _line) when is_binary(s), do: String.downcase(s)
  def call_method(s, "upper", [], _line) when is_binary(s), do: String.upcase(s)
  def call_method(s, "strip", [], _line) when is_binary(s), do: String.trim(s)

  def call_method(s, "strip", [chars], _line) when is_binary(s),
    do: String.trim(s, chars)

  def call_method(s, "lstrip", [], _line) when is_binary(s), do: String.trim_leading(s)
  def call_method(s, "rstrip", [], _line) when is_binary(s), do: String.trim_trailing(s)
  def call_method(s, "split", [], _line) when is_binary(s), do: String.split(s)
  def call_method(s, "split", [sep], _line) when is_binary(s), do: String.split(s, sep)

  def call_method(s, "startswith", [prefix], _line) when is_binary(s),
    do: String.starts_with?(s, prefix)

  def call_method(s, "endswith", [suffix], _line) when is_binary(s),
    do: String.ends_with?(s, suffix)

  def call_method(s, "replace", [a, b], _line) when is_binary(s),
    do: String.replace(s, a, b)

  def call_method(s, "join", [items], _line) when is_binary(s),
    do: Enum.map_join(items, s, &to_s/1)

  def call_method(m, "get", [key], _line) when is_map(m), do: Map.get(m, key, nil)

  def call_method(m, "get", [key, default], _line) when is_map(m),
    do: Map.get(m, key, default)

  def call_method(m, "items", [], _line) when is_map(m),
    do: Enum.map(m, fn {k, v} -> [k, v] end)

  def call_method(m, "keys", [], _line) when is_map(m), do: Map.keys(m)
  def call_method(m, "values", [], _line) when is_map(m), do: Map.values(m)

  def call_method(l, "index", [item], _line) when is_list(l),
    do: Enum.find_index(l, &equal?(&1, item))

  def call_method(l, "count", [item], _line) when is_list(l),
    do: Enum.count(l, &equal?(&1, item))

  def call_method(value, name, _args, line)
      when is_list(value) and name in ~w(append extend insert pop remove) do
    raise Error.new(
            {:unsupported_method, name},
            "list.#{name}() mutates a list, which is not supported",
            line
          )
  end

  def call_method(value, name, _args, line),
    do:
      raise(
        Error.new(
          {:unsupported_method, name},
          "#{type_name(value)}.#{name}() is not supported",
          line
        )
      )

  def filter("trim", v, [], _), do: v |> to_s() |> String.trim()
  def filter("lower", v, [], _), do: v |> to_s() |> String.downcase()
  def filter("upper", v, [], _), do: v |> to_s() |> String.upcase()

  def filter("title", v, [], _),
    do: v |> to_s() |> String.split(" ") |> Enum.map_join(" ", &String.capitalize/1)

  def filter("capitalize", v, [], _), do: v |> to_s() |> String.capitalize()
  def filter("replace", v, [a, b], _), do: v |> to_s() |> String.replace(to_s(a), to_s(b))
  def filter("string", v, [], _), do: to_s(v)
  def filter("as_text", v, [], _), do: to_s(v)
  def filter("length", v, [], line), do: size(v, line)
  def filter("count", v, [], line), do: size(v, line)
  def filter("join", v, [], _), do: Enum.map_join(v, "", &to_s/1)
  def filter("join", v, [sep], _), do: Enum.map_join(v, to_s(sep), &to_s/1)
  def filter("list", v, [], _) when is_binary(v), do: String.graphemes(v)
  def filter("list", v, [], _) when is_list(v), do: v
  def filter("list", v, [], _) when is_map(v), do: Map.keys(v)
  def filter("first", [h | _], [], _), do: h
  def filter("first", [], [], _), do: :undefined
  def filter("last", v, [], _) when is_list(v), do: List.last(v) || :undefined
  def filter("abs", v, [], _) when is_number(v), do: abs(v)
  def filter("round", v, [], _) when is_number(v), do: Float.round(v / 1, 0)
  def filter("round", v, [p], _) when is_number(v), do: Float.round(v / 1, p)
  def filter("default", v, args, _) when v in [:undefined], do: List.first(args, "")
  def filter("default", v, [d, true], _), do: if(truthy?(v), do: v, else: d)
  def filter("default", v, _args, _), do: v
  def filter("d", v, args, line), do: filter("default", v, args, line)
  def filter("unique", v, [], _) when is_list(v), do: Enum.uniq(v)
  def filter("sort", v, [], _) when is_list(v), do: Enum.sort(v)
  def filter("reverse", v, [], _) when is_list(v), do: Enum.reverse(v)
  def filter("reverse", v, [], _) when is_binary(v), do: String.reverse(v)

  def filter(name, v, [], line) when name in ["int", "as_number"] do
    cond do
      is_integer(v) -> v
      is_float(v) -> trunc(v)
      is_binary(v) -> parse_number(v, name, line)
      true -> 0
    end
  end

  def filter("float", v, [], line) do
    cond do
      is_number(v) -> v / 1
      is_binary(v) -> parse_number(v, "float", line) / 1
      true -> 0.0
    end
  end

  def filter("as_bool", v, [], _) when is_binary(v),
    do: String.downcase(String.trim(v)) in ["true", "1", "yes"]

  def filter("as_bool", v, [], _), do: truthy?(v)

  def filter(name, _v, _args, line),
    do:
      raise(Error.new({:unsupported_filter, name}, "the `#{name}` filter is not supported", line))

  defp parse_number(s, name, line) do
    s = String.trim(s)

    case Integer.parse(s) do
      {i, ""} ->
        i

      _ ->
        case Float.parse(s) do
          {f, ""} -> if name in ["int"], do: trunc(f), else: f
          _ -> raise Error.new(:bad_number, "`#{s}` is not a number", line)
        end
    end
  end

  defp size(v, _) when is_binary(v), do: String.length(v)
  defp size(v, _) when is_list(v), do: length(v)
  defp size(v, _) when is_map(v) and not is_struct(v), do: map_size(v)
  defp size(v, line), do: raise(Error.new(:bad_length, "#{type_name(v)} has no length", line))

  def test("defined", v, []), do: v != :undefined
  def test("undefined", v, []), do: v == :undefined
  def test("none", v, []), do: is_nil(v)
  def test("string", v, []), do: is_binary(v)
  def test("number", v, []), do: is_number(v)
  def test("integer", v, []), do: is_integer(v)
  def test("float", v, []), do: is_float(v)
  def test("boolean", v, []), do: is_boolean(v)
  def test("true", v, []), do: v === true
  def test("false", v, []), do: v === false
  def test("mapping", v, []), do: (is_map(v) and not is_struct(v)) or match?(%Object{}, v)
  def test("sequence", v, []), do: is_list(v) or is_binary(v)
  def test("iterable", v, []), do: is_list(v) or is_binary(v) or (is_map(v) and not is_struct(v))
  def test("callable", v, []), do: is_function(v) or match?(%Macro{}, v)
  def test("even", v, []) when is_integer(v), do: rem(v, 2) == 0
  def test("odd", v, []) when is_integer(v), do: rem(v, 2) == 1
  def test(name, v, [other]) when name in ["eq", "equalto", "=="], do: equal?(v, other)
  def test(name, v, [other]) when name in ["ne", "!="], do: not equal?(v, other)
  def test("sameas", v, [other]), do: v === other
  def test("in", v, [container]), do: contains?(container, v, nil)
  def test(name, _v, _args), do: {:unsupported, name}

  def iterate(list, _line) when is_list(list), do: list
  def iterate(binary, _line) when is_binary(binary), do: String.graphemes(binary)
  def iterate(map, _line) when is_map(map) and not is_struct(map), do: Map.keys(map)
  def iterate(:undefined, _line), do: []

  def iterate(value, line),
    do: raise(Error.new(:not_iterable, "#{type_name(value)} is not iterable", line))

  def type_name(v) when is_binary(v), do: "str"
  def type_name(v) when is_integer(v), do: "int"
  def type_name(v) when is_float(v), do: "float"
  def type_name(v) when is_boolean(v), do: "bool"
  def type_name(nil), do: "None"
  def type_name(:undefined), do: "undefined"
  def type_name(v) when is_list(v), do: "list"
  def type_name(%Object{}), do: "object"
  def type_name(%Macro{}), do: "macro"
  def type_name(v) when is_map(v), do: "dict"
  def type_name(v) when is_function(v), do: "function"
  def type_name(_), do: "value"
end
