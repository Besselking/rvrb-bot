defmodule Html do
  @escapes %{
    "&" => "&amp;",
    "<" => "&lt;",
    ">" => "&gt;",
    "\"" => "&quot;",
    "'" => "&#39;"
  }

  @doc """
  Escapes `value` for interpolation into the markup the bot sends to chat.

  RVRB renders bot messages as HTML, so anything the bot doesn't control -
  display names, track and artist names, the arguments someone typed after
  a command - has to come through here first. A stray `<` in a display
  name otherwise swallows the rest of a table row.

  `{:safe, html}` is the opt-out: it passes through untouched, for the
  handful of places that mean the markup they're building (album art
  `<img>`s, the `<span class="alert">` section headers, artist links).
  Wrap only markup you built yourself, and escape the values you
  interpolated into it.

  Non-binary values (numbers, atoms) are stringified first, and `nil`
  renders as an empty string.
  """
  def escape({:safe, html}), do: html
  def escape(nil), do: ""

  def escape(value) when is_binary(value),
    do: String.replace(value, ~w(& < > " '), &Map.fetch!(@escapes, &1))

  def escape(value), do: value |> to_string() |> escape()

  @doc """
  Renders a `chat-table` from `values` (a list of maps/keyword lists) using
  `keys` (a list of `{key, header_name}` pairs) to pick and label columns.

  Every cell, header and title goes through `escape/1`, so callers pass
  plain text and wrap anything that's deliberately markup in `{:safe, html}`.

  Pass `title: "..."` in `opts` for a single header cell (e.g. a
  "so-and-so's stats" title row) instead of one `<th>` per key. RVRB's
  chat HTML doesn't honor `colspan`, so the remaining columns are padded
  out with empty `<th>`s instead of spanning the title cell across them.

  A value of the shape `%{section: "..."}` renders as a header row in the
  middle of the body instead of a data row, for splitting a long table
  into labelled groups.
  """
  def table(values, keys \\ [], opts \\ []) do
    header =
      case Keyword.get(opts, :title) do
        nil ->
          header_names =
            Enum.map(keys, fn {_, header_name} -> ["<th>", escape(header_name), "</th>"] end)

          ["<thead><tr>", header_names, "</tr></thead>"]

        title ->
          ["<thead>", header_row(title, keys), "</thead>"]
      end

    rows =
      Enum.map(values, fn
        %{section: section} ->
          header_row(section, keys)

        value ->
          [
            "<tr>",
            Enum.map(keys, fn {key, _} ->
              ["<td>", escape(value[key]), "</td>"]
            end),
            "</tr>"
          ]
      end)

    [
      "<table class=\"chat-table striped\">",
      header,
      "<tbody>",
      rows,
      "</tbody>
      </table>"
    ]
    |> IO.iodata_to_binary()
  end

  defp header_row(text, keys) do
    padding = List.duplicate("<th></th>", max(length(keys) - 1, 0))
    ["<tr><th>", escape(text), "</th>", padding, "</tr>"]
  end
end
