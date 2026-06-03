defmodule Html do
  def table(values, keys \\ []) do
    header_names =
      Enum.map(keys, fn {_, header_name} ->
        ["<th>", header_name, "</th>"]
      end)

    header = ["<thead><tr>", header_names, "</tr></thead>"]

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
