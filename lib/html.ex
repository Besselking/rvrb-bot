defmodule Html do
  @doc """
  Renders a `chat-table` from `values` (a list of maps/keyword lists) using
  `keys` (a list of `{key, header_name}` pairs) to pick and label columns.

  Pass `title: "..."` in `opts` for a single header cell spanning all
  columns (e.g. a "so-and-so's stats" title row) instead of one `<th>` per
  key.
  """
  def table(values, keys \\ [], opts \\ []) do
    header =
      case Keyword.get(opts, :title) do
        nil ->
          header_names = Enum.map(keys, fn {_, header_name} -> ["<th>", header_name, "</th>"] end)
          ["<thead><tr>", header_names, "</tr></thead>"]

        title ->
          [
            "<thead><tr><th colspan=\"",
            Integer.to_string(length(keys)),
            "\">",
            title,
            "</th></tr></thead>"
          ]
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
