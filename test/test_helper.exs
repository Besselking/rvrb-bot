ExUnit.start()

# Every test that touches the database checks a connection out explicitly
# (see `Rvrb.DataCase`); nothing gets one just by being started.
Ecto.Adapters.SQL.Sandbox.mode(Rvrb.Repo, :manual)
