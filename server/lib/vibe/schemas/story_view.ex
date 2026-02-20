defmodule Vibe.Stories.StoryView do
  @moduledoc """
  Tracks story views - who viewed which story and when.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "story_views" do
    belongs_to :story, Vibe.Stories.Story, type: :binary_id
    belongs_to :viewer, Vibe.Accounts.User, type: :binary_id

    timestamps(updated_at: false)
  end

  def changeset(story_view, attrs) do
    story_view
    |> cast(attrs, [:story_id, :viewer_id])
    |> validate_required([:story_id, :viewer_id])
    |> unique_constraint([:story_id, :viewer_id])
  end
end
