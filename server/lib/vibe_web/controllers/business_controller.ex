defmodule VibeWeb.BusinessController do
  use VibeWeb, :controller
  alias Vibe.Accounts
  alias Vibe.Subscriptions

  def show(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      user ->
        has_access = Subscriptions.has_business_auto_reply?(user_id)

        json(conn, %{
          hasAccess: has_access,
          settings:
            if has_access do
              %{
                businessProfileEnabled: user.business_profile_enabled,
                autoReplyEnabled: user.auto_reply_enabled,
                autoReplyMessage: user.auto_reply_message,
                businessHoursStart: format_time(user.business_hours_start),
                businessHoursEnd: format_time(user.business_hours_end)
              }
            else
              nil
            end
        })
    end
    end
  end

  def update_settings(conn, params) do
    user_id = params["user_id"] || conn.assigns.current_user.id
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else

    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      user ->
        if not Subscriptions.has_business_auto_reply?(user_id) do
          conn |> put_status(403) |> json(%{error: "Upgrade to Silver or Gold to access business features"})
        else
          update_attrs =
            %{}
            |> maybe_put(:business_profile_enabled, params["businessProfileEnabled"])
            |> maybe_put(:auto_reply_enabled, params["autoReplyEnabled"])
            |> maybe_put(:auto_reply_message, params["autoReplyMessage"])
            |> maybe_put_time(:business_hours_start, params["businessHoursStart"])
            |> maybe_put_time(:business_hours_end, params["businessHoursEnd"])

          case Accounts.update_user(user, update_attrs) do
            {:ok, updated_user} ->
              json(conn, %{
                success: true,
                settings: %{
                  businessProfileEnabled: updated_user.business_profile_enabled,
                  autoReplyEnabled: updated_user.auto_reply_enabled,
                  autoReplyMessage: updated_user.auto_reply_message,
                  businessHoursStart: format_time(updated_user.business_hours_start),
                  businessHoursEnd: format_time(updated_user.business_hours_end)
                }
              })

            {:error, _changeset} ->
              conn |> put_status(400) |> json(%{error: "Failed to update settings"})
          end
        end
    end
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_time(map, _key, nil), do: map

  defp maybe_put_time(map, key, value) when is_binary(value) do
    case Time.from_iso8601(value) do
      {:ok, time} -> Map.put(map, key, time)
      _ -> map
    end
  end

  defp maybe_put_time(map, _key, _value), do: map

  defp format_time(nil), do: nil

  defp format_time(%Time{} = time) do
    time
    |> Time.to_iso8601()
    |> String.slice(0, 5)
  end
end
