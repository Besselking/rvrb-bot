defmodule Rvrb.DataCase do
  @moduledoc """
  Case template for tests that touch the database.

  Each test runs inside a sandbox transaction that is rolled back
  afterwards, so tests neither see each other's rows nor leave any behind.
  `async: true` is safe here - the sandbox hands every test its own
  connection - as long as the test only talks to the database through the
  checked-out one.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Ecto.Query
      import Rvrb.DataCase
      import Rvrb.Fixtures

      alias Rvrb.Repo
    end
  end

  @doc "A `%{field => [message]}` view of a changeset's errors, with interpolation applied."
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Rvrb.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end
end
