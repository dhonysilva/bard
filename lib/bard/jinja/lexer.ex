defmodule Bard.Jinja.Lexer do
  @moduledoc """
  Splits a template into text, `{{ }}` and `{% %}` tokens.

  Comments are dropped, `{% raw %}` blocks become text, and whitespace control
  is applied here: `{%-` removes all whitespace before the tag, `-%}` all
  whitespace after it. Like Jinja's default, one trailing newline at the end
  of the template is removed.

  Tokens: `{:text, binary}`, `{:output, source, line}`, `{:tag, source, line}`.
  """

  alias Bard.Jinja.Error

  @spec tokenize(String.t()) :: {:ok, list()} | {:error, Error.t()}
  def tokenize(source) do
    source = drop_trailing_newline(source)

    case scan(source, 1, []) do
      {:ok, raw} -> {:ok, apply_whitespace_control(raw)}
      {:error, _} = error -> error
    end
  end

  defp drop_trailing_newline(source) do
    cond do
      String.ends_with?(source, "\r\n") -> binary_part(source, 0, byte_size(source) - 2)
      String.ends_with?(source, "\n") -> binary_part(source, 0, byte_size(source) - 1)
      true -> source
    end
  end

  # Raw tokens carry strip flags: {:text, s} | {kind, src, line, lstrip?, rstrip?}
  defp scan("", _line, acc), do: {:ok, Enum.reverse(acc)}

  defp scan(source, line, acc) do
    case :binary.match(source, ["{{", "{%", "{#"]) do
      :nomatch ->
        {:ok, Enum.reverse([{:text, source} | acc])}

      {pos, 2} ->
        text = binary_part(source, 0, pos)
        line = line + count_newlines(text)
        open = binary_part(source, pos, 2)
        rest = binary_part(source, pos + 2, byte_size(source) - pos - 2)
        {lstrip, rest} = strip_marker(rest)
        acc = if text == "", do: acc, else: [{:text, text} | acc]

        case open do
          "{#" -> comment(rest, line, lstrip, acc)
          "{{" -> tag(rest, line, lstrip, :output, "}}", acc)
          "{%" -> tag(rest, line, lstrip, :tag, "%}", acc)
        end
    end
  end

  defp strip_marker("-" <> rest), do: {true, rest}
  defp strip_marker("+" <> rest), do: {false, rest}
  defp strip_marker(rest), do: {false, rest}

  defp comment(rest, line, lstrip, acc) do
    case :binary.match(rest, "#}") do
      :nomatch ->
        {:error, Error.new(:unclosed_comment, "unclosed comment", line)}

      {pos, 2} ->
        body = binary_part(rest, 0, pos)
        rstrip = String.ends_with?(body, "-")
        after_tag = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)
        scan(after_tag, line + count_newlines(body), [{:comment, "", line, lstrip, rstrip} | acc])
    end
  end

  defp tag(rest, line, lstrip, kind, close, acc) do
    case find_close(rest, close, 0, nil) do
      nil ->
        {:error,
         Error.new(:unclosed_tag, "unclosed #{if kind == :output, do: "{{", else: "{%"}", line)}

      pos ->
        body = binary_part(rest, 0, pos)

        {body, rstrip} =
          if String.ends_with?(body, "-"),
            do: {binary_part(body, 0, byte_size(body) - 1), true},
            else: {body, false}

        after_tag = binary_part(rest, pos + 2, byte_size(rest) - pos - 2)
        next_line = line + count_newlines(body)

        if kind == :tag and String.trim(body) == "raw" do
          raw_block(after_tag, line, lstrip, rstrip, acc)
        else
          scan(after_tag, next_line, [{kind, String.trim(body), line, lstrip, rstrip} | acc])
        end
    end
  end

  # The closing delimiter, skipping anything inside string literals.
  defp find_close(source, _close, pos, _quote) when pos >= byte_size(source), do: nil

  defp find_close(source, close, pos, nil) do
    case binary_part(source, pos, 1) do
      q when q in ["'", "\""] ->
        find_close(source, close, pos + 1, q)

      _ ->
        if pos + 2 <= byte_size(source) and binary_part(source, pos, 2) == close,
          do: pos,
          else: find_close(source, close, pos + 1, nil)
    end
  end

  defp find_close(source, close, pos, quote) do
    case binary_part(source, pos, 1) do
      "\\" -> find_close(source, close, pos + 2, quote)
      ^quote -> find_close(source, close, pos + 1, nil)
      _ -> find_close(source, close, pos + 1, quote)
    end
  end

  @endraw ~r/\{%(-?)\s*endraw\s*(-?)%\}/

  defp raw_block(source, line, lstrip, rstrip, acc) do
    case Regex.run(@endraw, source, return: :index) do
      nil ->
        {:error, Error.new(:unclosed_raw, "unclosed {% raw %}", line)}

      [{start, len}, {_, l_len}, {_, r_len}] ->
        text = binary_part(source, 0, start)
        text = if rstrip, do: String.trim_leading(text), else: text
        text = if l_len > 0, do: String.trim_trailing(text), else: text
        rest = binary_part(source, start + len, byte_size(source) - start - len)
        # Markers carry the raw tags' outer strip flags to the text around the block.
        before = {:comment, "", line, lstrip, false}
        after_block = {:comment, "", line, false, r_len > 0}
        scan(rest, line + count_newlines(text), [after_block, {:raw_text, text}, before | acc])
    end
  end

  defp count_newlines(text), do: text |> :binary.matches("\n") |> length()

  # Apply `-` markers to neighbouring text, then drop comment markers.
  defp apply_whitespace_control(raw) do
    raw
    |> Enum.with_index()
    |> then(fn indexed ->
      strip_before = for {{_k, _s, _l, true, _r}, i} <- indexed, into: MapSet.new(), do: i - 1
      strip_after = for {{_k, _s, _l, _ls, true}, i} <- indexed, into: MapSet.new(), do: i + 1

      Enum.flat_map(indexed, fn
        {{:text, text}, i} ->
          text = if MapSet.member?(strip_before, i), do: String.trim_trailing(text), else: text
          text = if MapSet.member?(strip_after, i), do: String.trim_leading(text), else: text
          if text == "", do: [], else: [{:text, text}]

        {{:raw_text, text}, _i} ->
          if text == "", do: [], else: [{:text, text}]

        {{:comment, _, _, _, _}, _i} ->
          []

        {{kind, src, line, _ls, _rs}, _i} ->
          [{kind, src, line}]
      end)
    end)
  end
end
