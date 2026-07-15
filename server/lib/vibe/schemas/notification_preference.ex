defmodule Vibe.Schemas.NotificationPreference do
  use Ecto.Schema
  import Ecto.Changeset

  @categories ~w(private_chats group_chats channels stories reactions)

  @default_category_settings %{"enabled" => true, "preview" => true, "sound" => true}

  @default_preferences %{
    "categories" => Map.new(@categories, &{&1, @default_category_settings}),
    "in_app_sounds" => true,
    "in_app_vibrate" => true,
    "in_app_preview" => true,
    "names_on_lock_screen" => true
  }

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "notification_preferences" do
    field :user_id, :binary_id
    field :preferences, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
  def default_preferences, do: @default_preferences

  def changeset(notification_preference, attrs) do
    notification_preference
    |> cast(attrs, [:user_id, :preferences])
    |> validate_required([:user_id])
  end
end
