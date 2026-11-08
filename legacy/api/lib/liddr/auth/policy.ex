defmodule Liddr.Auth.Policy do
  alias Liddr.Accounts.User
  alias Liddr.Repo

  @blocked_user_statuses ~w(suspended banned deactivated)

  def fetch_user(user_id) do
    case Repo.get(User, user_id) do
      nil -> {:error, :user_not_found}
      %User{} = user -> {:ok, user}
    end
  end

  def ensure_user_can_authenticate(nil), do: :ok

  def ensure_user_can_authenticate(%User{} = user) do
    case normalize_account_status(user.account_status) do
      "suspended" -> {:error, :account_suspended}
      "banned" -> {:error, :account_banned}
      "deactivated" -> {:error, :account_deactivated}
      _ -> :ok
    end
  end

  defp normalize_account_status(nil), do: "active"
  defp normalize_account_status(status) when status in @blocked_user_statuses, do: status
  defp normalize_account_status(status) when is_binary(status), do: status
  defp normalize_account_status(_status), do: "active"
end
