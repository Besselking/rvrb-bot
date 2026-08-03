defmodule Html do
  @doc """
  Renders a `chat-table` from `values` (a list of maps/keyword lists) using
  `keys` (a list of `{key, header_name}` pairs) to pick and label columns.

  Pass `title: "..."` in `opts` for a single header cell (e.g. a
  "so-and-so's stats" title row) instead of one `<th>` per key. RVRB's
  chat HTML doesn't honor `colspan`, so the remaining columns are padded
  out with empty `<th>`s instead of spanning the title cell across them.
  """
  def table(values, keys \\ [], opts \\ []) do
    header =
      case Keyword.get(opts, :title) do
        nil ->
          header_names = Enum.map(keys, fn {_, header_name} -> ["<th>", header_name, "</th>"] end)
          ["<thead><tr>", header_names, "</tr></thead>"]

        title ->
          padding = List.duplicate("<th></th>", max(length(keys) - 1, 0))
          ["<thead><tr><th>", title, "</th>", padding, "</tr></thead>"]
      end

    rows =
      Enum.map(values, fn value ->
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
end
