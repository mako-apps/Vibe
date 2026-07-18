defmodule VibeWeb.SettingsController do
  use VibeWeb, :controller

  alias Vibe.Accounts
  alias Vibe.Notifications

  @privacy_keys ~w(forwarded_messages calls phone_number profile_photos bio gifts birthday saved_music)

  def show(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      privacy: Accounts.privacy_settings(user),
      notifications: Notifications.get_notification_preferences(user.id)
    })
  end

  def index(conn, _params) do
    json(conn, Notifications.get_notification_preferences(conn.assigns.current_user.id))
  end

  def update(conn, params) when is_map(params) do
    case Notifications.update_notification_preferences(conn.assigns.current_user.id, params) do
      {:ok, preferences} -> json(conn, preferences)
      {:error, changeset} -> validation_error(conn, changeset)
    end
  end

  def update(conn, _params), do: invalid_payload(conn, "preferences must be an object")

  def update_privacy(conn, %{"privacy" => privacy}) when is_map(privacy) do
    if Map.keys(privacy) -- @privacy_keys == [] do
      case Accounts.update_privacy_settings(conn.assigns.current_user, privacy) do
        {:ok, user} -> json(conn, %{privacy: Accounts.privacy_settings(user)})
        {:error, changeset} -> validation_error(conn, changeset)
      end
    else
      invalid_payload(conn, "privacy contains unsupported keys")
    end
  end

  def update_privacy(conn, _params), do: invalid_payload(conn, "privacy must be an object")

  def update_notifications(conn, %{"notifications" => notifications})
      when is_map(notifications) do
    case Notifications.update_notification_preferences(
           conn.assigns.current_user.id,
           notifications
         ) do
      {:ok, preferences} -> json(conn, %{notifications: preferences})
      {:error, changeset} -> validation_error(conn, changeset)
    end
  end

  def update_notifications(conn, _params),
    do: invalid_payload(conn, "notifications must be an object")

  defp invalid_payload(conn, message) do
    conn |> put_status(:unprocessable_entity) |> json(%{error: message})
  end

  defp validation_error(conn, changeset) do
    details =
      Ecto.Changeset.traverse_errors(changeset, fn {message, options} ->
        Enum.reduce(options, message, fn {key, value}, acc ->
          String.replace(acc, "%{#{key}}", to_string(value))
        end)
      end)

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "Invalid settings", details: details})
  end
end
