defmodule HtmlTest do
  use ExUnit.Case, async: true

  @keys [{:label, "Label"}, {:value, "Value"}]

  describe "table/3" do
    test "renders one header cell per key by default" do
      html = Html.table([%{label: "a", value: "b"}], @keys)

      assert html =~ "<thead><tr><th>Label</th><th>Value</th></tr></thead>"
      assert html =~ "<tr><td>a</td><td>b</td></tr>"
    end

    test "a title sits above the per-key headers, padded out to the column count" do
      html = Html.table([%{label: "a", value: "b"}], @keys, title: "Bess's stats")

      assert html =~
               "<thead><tr><th>Bess&#39;s stats</th><th></th></tr>" <>
                 "<tr><th>Label</th><th>Value</th></tr></thead>"
    end

    test "unlabelled keys render no per-key header row under the title" do
      html =
        Html.table([%{label: "a", value: "b"}], [{:label, nil}, {:value, nil}], title: "Stats")

      assert html =~ "<thead><tr><th>Stats</th><th></th></tr></thead>"
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

      assert html =~ "<tr><th>Bess&#39;s stats</th><th></th></tr>"
      assert html =~ "<tr><th>Profile</th><th></th></tr>"
    end

    test "cell values are escaped" do
      html = Html.table([%{label: "<img src=x onerror=alert(1)>", value: "a & b"}], @keys)

      assert html =~ "<td>&lt;img src=x onerror=alert(1)&gt;</td>"
      assert html =~ "<td>a &amp; b</td>"
    end

    test "titles, sections and header names are escaped" do
      html =
        Html.table([%{section: "<b>hi</b>"}], [{:label, "<em>Label</em>"}, {:value, "Value"}],
          title: "</table>"
        )

      assert html =~ "<th>&lt;/table&gt;</th>"
      assert html =~ "<th>&lt;b&gt;hi&lt;/b&gt;</th>"

      refute Html.table([%{label: "a", value: "b"}], [{:label, "<em>Label</em>"}]) =~
               "<th><em>Label</em></th>"
    end

    test "a {:safe, html} value passes through unescaped" do
      html = Html.table([%{label: {:safe, "<img src=\"art.png\"/>"}, value: "b"}], @keys)

      assert html =~ "<td><img src=\"art.png\"/></td>"
    end

    test "nil and non-binary values render without blowing up" do
      html = Html.table([%{label: nil, value: 42}], @keys)

      assert html =~ "<td></td><td>42</td>"
    end
  end

  describe "escape/1" do
    test "escapes the five markup-significant characters" do
      assert Html.escape("&<>\"'") == "&amp;&lt;&gt;&quot;&#39;"
    end

    test "escapes ampersands once, not twice" do
      assert Html.escape("a &amp; b") == "a &amp;amp; b"
    end

    test "leaves everything else alone, multibyte included" do
      assert Html.escape("Bess 🐸 — ▶ ✅") == "Bess 🐸 — ▶ ✅"
    end

    test "passes {:safe, html} through and stringifies other terms" do
      assert Html.escape({:safe, "<br>"}) == "<br>"
      assert Html.escape(nil) == ""
      assert Html.escape(42) == "42"
    end
  end
end
