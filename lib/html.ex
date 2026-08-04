defmodule Html do
  @doc """
  Renders a `chat-table` from `values` (a list of maps/keyword lists) using
  `keys` (a list of `{key, header_name}` pairs) to pick and label columns.

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
          header_names = Enum.map(keys, fn {_, header_name} -> ["<th>", header_name, "</th>"] end)
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
              ["<td>", value[key], "</td>"]
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
    ["<tr><th>", text, "</th>", padding, "</tr>"]
  end
end
