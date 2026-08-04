defmodule HtmlTest do
  use ExUnit.Case, async: true

  @keys [{:label, "Label"}, {:value, "Value"}]

  describe "table/3" do
    test "renders one header cell per key by default" do
      html = Html.table([%{label: "a", value: "b"}], @keys)

      assert html =~ "<thead><tr><th>Label</th><th>Value</th></tr></thead>"
      assert html =~ "<tr><td>a</td><td>b</td></tr>"
    end

    test "a title replaces the per-key headers, padded out to the column count" do
      html = Html.table([%{label: "a", value: "b"}], @keys, title: "Bess's stats")

      assert html =~ "<thead><tr><th>Bess's stats</th><th></th></tr></thead>"
      refute html =~ "<th>Label</th>"
    end

    test "a section value renders as a header row inside the body" do
      html =
        Html.table(
          [%{section: "Profile"}, %{label: "Member since", value: "a year ago"}],
          @keys
        )

      assert html =~ "<tbody><tr><th>Profile</th><th></th></tr>"
      assert html =~ "<tr><td>Member since</td><td>a year ago</td></tr>"
    end

    test "sections are padded to the same width as a title row" do
      html = Html.table([%{section: "Profile"}], @keys, title: "Bess's stats")

      assert html =~ "<tr><th>Bess's stats</th><th></th></tr>"
      assert html =~ "<tr><th>Profile</th><th></th></tr>"
    end
  end
end
