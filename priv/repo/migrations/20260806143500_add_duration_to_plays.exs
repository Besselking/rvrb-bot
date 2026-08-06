defmodule Rvrb.Repo.Migrations.AddDurationToPlays do
  use Ecto.Migration

  def change do
    alter table(:plays) do
      # Nullable: RVRB doesn't guarantee a duration on every track payload,
      # and plays recorded before this column existed have none either.
      # `\rotation` averages over the plays that do have one.
      add :duration_ms, :integer
    end
  end
end
