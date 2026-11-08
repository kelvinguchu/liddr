defmodule Liddr.Moderation.EnforcementLifecycle do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Location.DriverHotState
  alias Liddr.Moderation.Query
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent

  @default_limit 200
  @max_limit 1_000

  def expire_due_temporary_suspensions(attrs \\ %{}) do
    now = resolve_now(attrs)
    limit = resolve_limit(attrs)

    due_ids =
      Repo.all(
        from(ue in UserEnforcement,
          where:
            ue.status == "active" and ue.action == "temporary_suspension" and ue.ends_at <= ^now,
          order_by: [asc: ue.ends_at, asc: ue.id],
          select: ue.id,
          limit: ^limit
        )
      )

    {:ok, Enum.map(due_ids, &expire_single_enforcement(&1, now))}
  end

  defp expire_single_enforcement(enforcement_id, now) do
    Repo.transaction(fn ->
      enforcement =
        Repo.one(
          from(ue in UserEnforcement,
            where: ue.id == ^enforcement_id,
            lock: "FOR UPDATE"
          )
        ) || Repo.rollback(:enforcement_not_found)

      cond do
        enforcement.status != "active" ->
          %{enforcement_id: enforcement_id, status: "already_processed"}

        enforcement.action != "temporary_suspension" ->
          %{enforcement_id: enforcement_id, status: "unsupported_action"}

        is_nil(enforcement.ends_at) or DateTime.compare(enforcement.ends_at, now) == :gt ->
          %{enforcement_id: enforcement_id, status: "not_due"}

        true ->
          enforcement
          |> Ecto.Changeset.change(%{status: "expired", lifted_at: now})
          |> Repo.update()
          |> unwrap_or_rollback()

          sync_user_and_driver_state!(enforcement.user_id, now)

          %{enforcement_id: enforcement_id, status: "expired", user_id: enforcement.user_id}
      end
    end)
    |> case do
      {:ok, value} ->
        value

      {:error, reason} ->
        %{enforcement_id: enforcement_id, status: "error", reason: inspect(reason)}
    end
  end

  defp sync_user_and_driver_state!(user_id, now) do
    active_enforcements = fetch_active_enforcements_for_user!(user_id)
    user = fetch_user_for_update!(user_id)
    user_state = effective_user_state(active_enforcements)

    user
    |> User.account_status_changeset(user_state_to_user_attrs(user_state))
    |> Repo.update()
    |> unwrap_or_rollback()

    sync_driver_state!(user_id, user_state, now)
  end

  defp fetch_active_enforcements_for_user!(user_id) do
    Repo.all(
      from(ue in UserEnforcement,
        where: ue.user_id == ^user_id and ue.status == "active",
        order_by: [desc: ue.starts_at, desc: ue.id],
        lock: "FOR UPDATE"
      )
    )
  end

  defp fetch_user_for_update!(user_id) do
    Repo.one(
      from(u in User,
        where: u.id == ^user_id,
        lock: "FOR UPDATE"
      )
    ) || Repo.rollback(:user_not_found)
  end

  defp effective_user_state(active_enforcements) do
    permanent_ban =
      Enum.find(active_enforcements, fn enforcement -> enforcement.action == "permanent_ban" end)

    temporary_suspension =
      active_enforcements
      |> Enum.filter(fn enforcement -> enforcement.action == "temporary_suspension" end)
      |> latest_temporary_suspension()

    feature_restriction =
      Enum.find(active_enforcements, fn enforcement ->
        enforcement.action == "feature_restriction"
      end)

    warning =
      Enum.find(active_enforcements, fn enforcement -> enforcement.action == "warning" end)

    cond do
      permanent_ban ->
        %{
          account_status: "banned",
          reason_code: permanent_ban.reason_code,
          restricted_at: permanent_ban.starts_at,
          restricted_until: nil,
          banned_at: permanent_ban.starts_at
        }

      temporary_suspension ->
        %{
          account_status: "suspended",
          reason_code: temporary_suspension.reason_code,
          restricted_at: temporary_suspension.starts_at,
          restricted_until: temporary_suspension.ends_at,
          banned_at: nil
        }

      feature_restriction ->
        %{
          account_status: "restricted",
          reason_code: feature_restriction.reason_code,
          restricted_at: feature_restriction.starts_at,
          restricted_until: nil,
          banned_at: nil
        }

      warning ->
        %{
          account_status: "active",
          reason_code: warning.reason_code,
          restricted_at: nil,
          restricted_until: nil,
          banned_at: nil
        }

      true ->
        %{
          account_status: "active",
          reason_code: nil,
          restricted_at: nil,
          restricted_until: nil,
          banned_at: nil
        }
    end
  end

  defp user_state_to_user_attrs(user_state) do
    %{
      account_status: user_state.account_status,
      account_status_reason_code: user_state.reason_code,
      account_restricted_at: user_state.restricted_at,
      account_restricted_until: user_state.restricted_until,
      account_banned_at: user_state.banned_at
    }
  end

  defp sync_driver_state!(user_id, user_state, now) do
    driver =
      Repo.one(
        from(d in Driver,
          where: d.user_id == ^user_id,
          lock: "FOR UPDATE"
        )
      )

    if driver do
      attrs = desired_driver_attrs(driver, user_state.account_status, now)

      if driver_state_changed?(driver, attrs) do
        previous_status = driver.account_status

        updated_driver =
          driver
          |> Driver.create_changeset(attrs)
          |> Repo.update()
          |> unwrap_or_rollback()

        :ok = DriverHotState.put(updated_driver)

        %DriverActivityEvent{}
        |> DriverActivityEvent.create_changeset(%{
          "driver_id" => updated_driver.user_id,
          "event_type" => "status_changed",
          "previous_value" => previous_status,
          "new_value" => updated_driver.account_status,
          "reason_code" => user_state.reason_code || "enforcement_state_sync",
          "actor_type" => "system",
          "payload" => %{
            "source" => "moderation_enforcement_lifecycle",
            "is_available" => updated_driver.is_available
          }
        })
        |> Repo.insert()
        |> unwrap_or_rollback()
      end
    end
  end

  defp desired_driver_attrs(driver, "banned", now) do
    %{
      "account_status" => "deactivated",
      "is_available" => false,
      "suspended_at" => driver.suspended_at || now,
      "last_seen_at" => now
    }
  end

  defp desired_driver_attrs(driver, "suspended", now) do
    %{
      "account_status" => "suspended",
      "is_available" => false,
      "suspended_at" => driver.suspended_at || now,
      "last_seen_at" => now
    }
  end

  defp desired_driver_attrs(driver, _user_status, now) do
    account_status =
      case driver.verification_status do
        "approved" -> "active"
        "suspended" -> "suspended"
        _ -> "pending"
      end

    %{
      "account_status" => account_status,
      "is_available" => false,
      "suspended_at" =>
        if(account_status == "suspended", do: driver.suspended_at || now, else: nil),
      "last_seen_at" => now
    }
  end

  defp driver_state_changed?(driver, attrs) do
    driver.account_status != Map.get(attrs, "account_status") or
      driver.is_available != Map.get(attrs, "is_available") or
      driver.suspended_at != Map.get(attrs, "suspended_at")
  end

  defp resolve_now(attrs) do
    case Query.get_value(attrs, :now) do
      %DateTime{} = value -> value
      _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
    end
  end

  defp resolve_limit(attrs) do
    attrs
    |> Query.get_value(:limit)
    |> Query.parse_integer()
    |> case do
      parsed when is_integer(parsed) and parsed > 0 and parsed <= @max_limit -> parsed
      _ -> @default_limit
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)

  defp latest_temporary_suspension([]), do: nil

  defp latest_temporary_suspension(enforcements) do
    Enum.max_by(
      enforcements,
      fn enforcement -> DateTime.to_unix(enforcement.ends_at, :microsecond) end
    )
  end
end
