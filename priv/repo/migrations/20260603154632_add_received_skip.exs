defmodule Rvrb.Repo.Migrations.AddReceivedSkip do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :received_skip, :boolean, default: false
    end
  end
end
