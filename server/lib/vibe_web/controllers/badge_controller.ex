defmodule VibeWeb.BadgeController do
  use VibeWeb, :controller
  alias Vibe.Badges
  alias Vibe.Accounts

  def index(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      _user ->
        badges = Badges.list_badges(user_id)
        active_badge = Badges.get_active_badge(user_id)

        json(conn, %{
          activeBadge:
            if active_badge do
              %{
                type: active_badge.badge_type,
                earnedAt: active_badge.earned_at,
                source: active_badge.source
              }
            else
              nil
            end,
          allBadges:
            Enum.map(badges, fn badge ->
              %{
                type: badge.badge_type,
                earnedAt: badge.earned_at,
                source: badge.source,
                active: badge.active
              }
            end)
        })
    end
    end
  end
end
