defmodule VibeWeb.ReferralController do
  use VibeWeb, :controller
  alias Vibe.Referrals
  alias Vibe.Accounts

  def get_code(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      _user ->
        case Referrals.get_or_create_referral_code(user_id) do
          {:ok, code} ->
            json(conn, %{code: code})

          {:error, _reason} ->
            conn |> put_status(500) |> json(%{error: "Failed to generate referral code"})
        end
    end
    end
  end

  def stats(conn, %{"user_id" => user_id}) do
    current_id = conn.assigns.current_user.id

    if user_id != current_id do
      conn |> put_status(:forbidden) |> json(%{error: "Forbidden"})
    else
    case Accounts.get_user(user_id) do
      nil ->
        conn |> put_status(404) |> json(%{error: "User not found"})

      _user ->
        stats = Referrals.get_referral_stats(user_id)

        json(conn, %{
          referralCode: stats.referral_code,
          verifiedCount: stats.verified_count,
          pendingCount: stats.pending_count,
          totalCount: stats.total_count,
          bronzeThreshold: stats.bronze_threshold,
          progressPercent: stats.progress_percent
        })
    end
    end
  end

  def apply_code(conn, %{"code" => code}) do
    user_id = conn.assigns.current_user.id
    case Referrals.track_referral(code, user_id) do
      {:ok, _referral} ->
        json(conn, %{success: true, message: "Referral tracked successfully"})

      {:error, :invalid_code} ->
        conn |> put_status(400) |> json(%{error: "Invalid referral code"})

      {:error, :self_referral} ->
        conn |> put_status(400) |> json(%{error: "Cannot use your own referral code"})

      {:error, _reason} ->
        conn |> put_status(400) |> json(%{error: "Failed to apply referral code"})
    end
  end

  def verify(conn, _params) do
    user_id = conn.assigns.current_user.id
    case Referrals.verify_referral(user_id) do
      {:ok, _} ->
        json(conn, %{success: true})

      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: inspect(reason)})
    end
  end
end
