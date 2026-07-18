defmodule Vibe.SettingsTest do
  use ExUnit.Case, async: true

  alias Vibe.Schemas.NotificationPreference

  test "notification preferences reject unsupported keys" do
    changeset = NotificationPreference.changeset(%NotificationPreference{}, %{
      user_id: Ecto.UUID.generate(),
      preferences: %{"unknown" => true}
    })

    refute changeset.valid?
  end

  test "notification preferences accept deep partial category updates" do
    changeset = NotificationPreference.changeset(%NotificationPreference{}, %{
      user_id: Ecto.UUID.generate(),
      preferences: %{"categories" => %{"private_chats" => %{"enabled" => false}}}
    })

    assert changeset.valid?
  end
end
