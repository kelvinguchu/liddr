defmodule Liddr.Moderation.Enforcements do
  import Ecto.Query

  alias Liddr.Accounts.Driver
  alias Liddr.Accounts.User
  alias Liddr.Moderation.Query
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Verification.DriverActivityEvent

  @enforcement_sort_fields %{
    "inserted_at" => :inserted_at,
    "starts_at" => :starts_at,
    "status" => :status,
    "action" => :action
  }
  @default_due_within_hours 24
  @max_due_within_hours 720

  def apply_enforcement(attrs) do
    Repo.transaction(fn ->
      apply_enforcement_in_transaction!(attrs)
    end)
    |> case do
      {:ok, enforcement} -> {:ok, enforcement}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_enforcement_in_transaction!(attrs) do
    starts_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    enforcement_attrs =
      attrs
      |> Map.new()
      |> Map.put_new("scope", "platform")
      |> Map.put_new("status", "active")
      |> Map.put_new("starts_at", starts_at)

    enforcement =
      %UserEnforcement{}
      |> UserEnforcement.create_changeset(enforcement_attrs)
      |> Repo.insert()
      |> unwrap_or_rollback()

    user = Repo.get(User, enforcement.user_id) || Repo.rollback(:user_not_found)

    user
    |> User.account_status_changeset(account_status_update_attrs(enforcement))
    |> Repo.update()
    |> unwrap_or_rollback()

    apply_driver_enforcement!(enforcement)

    enforcement
  end

  def list_enforcements(attrs \\ %{}) do
    from(ue in UserEnforcement)
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.maybe_filter_equals(:action, Query.get_value(attrs, :action))
    |> Query.maybe_filter_equals(:user_id, Query.parse_integer(Query.get_value(attrs, :user_id)))
    |> Query.maybe_filter_equals(
      :report_id,
      Query.parse_integer(Query.get_value(attrs, :report_id))
    )
    |> Query.apply_sort(attrs, @enforcement_sort_fields, :inserted_at)
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def enforcement_metrics(attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    scope = Query.get_value(attrs, :scope) |> Query.normalize_text()

    with {:ok, due_within_hours} <- resolve_due_within_hours(attrs) do
      due_by = DateTime.add(now, due_within_hours * 3600, :second)
      base_query = from(ue in UserEnforcement) |> Query.maybe_filter_equals(:scope, scope)

      by_action_status =
        Repo.all(
          from ue in base_query,
            group_by: [ue.action, ue.status],
            select: %{action: ue.action, status: ue.status, count: count(ue.id)},
            order_by: [asc: ue.action, asc: ue.status]
        )

      active_total =
        Repo.aggregate(
          from(ue in base_query, where: ue.status == "active"),
          :count,
          :id
        )

      active_temporary_query =
        from ue in base_query,
          where:
            ue.status == "active" and ue.action == "temporary_suspension" and
              not is_nil(ue.ends_at)

      due_soon_temporary_suspensions =
        Repo.aggregate(
          from(
            ue in active_temporary_query,
            where: ue.ends_at > ^now and ue.ends_at <= ^due_by
          ),
          :count,
          :id
        )

      overdue_temporary_suspensions =
        Repo.aggregate(
          from(ue in active_temporary_query, where: ue.ends_at <= ^now),
          :count,
          :id
        )

      {:ok,
       %{
         summary: %{
           active_total: active_total,
           due_within_hours: due_within_hours,
           due_soon_temporary_suspensions: due_soon_temporary_suspensions,
           overdue_temporary_suspensions: overdue_temporary_suspensions
         },
         by_action_status: by_action_status
       }}
    end
  end

  defp apply_driver_enforcement!(%UserEnforcement{} = enforcement) do
    driver = Repo.get(Driver, enforcement.user_id)
    attrs = driver_update_attrs(enforcement)

    cond do
      is_nil(driver) ->
        :ok

      is_nil(attrs) ->
        :ok

      true ->
        previous_status = driver.account_status

        updated_driver =
          driver
          |> Driver.create_changeset(attrs)
          |> Repo.update()
          |> unwrap_or_rollback()

        %DriverActivityEvent{}
        |> DriverActivityEvent.create_changeset(%{
          "driver_id" => updated_driver.user_id,
          "event_type" => "status_changed",
          "previous_value" => previous_status,
          "new_value" => updated_driver.account_status,
          "reason_code" => enforcement.reason_code || "moderation_enforcement",
          "reason_text" => enforcement.reason_text,
          "actor_type" => "ops",
          "actor_user_id" => enforcement.actor_user_id,
          "payload" => %{
            "enforcement_id" => enforcement.id,
            "action" => enforcement.action,
            "scope" => enforcement.scope,
            "is_available" => updated_driver.is_available
          }
        })
        |> Repo.insert()
        |> unwrap_or_rollback()

        :ok
    end
  end

  defp account_status_update_attrs(%UserEnforcement{action: "warning", reason_code: reason_code}) do
    %{
      account_status: "active",
      account_status_reason_code: reason_code,
      account_restricted_at: nil,
      account_restricted_until: nil,
      account_banned_at: nil
    }
  end

  defp account_status_update_attrs(%UserEnforcement{
         action: "feature_restriction",
         reason_code: reason_code,
         starts_at: starts_at
       }) do
    %{
      account_status: "restricted",
      account_status_reason_code: reason_code,
      account_restricted_at: starts_at,
      account_banned_at: nil
    }
  end

  defp account_status_update_attrs(%UserEnforcement{
         action: "temporary_suspension",
         reason_code: reason_code,
         starts_at: starts_at,
         ends_at: ends_at
       }) do
    %{
      account_status: "suspended",
      account_status_reason_code: reason_code,
      account_restricted_at: starts_at,
      account_restricted_until: ends_at,
      account_banned_at: nil
    }
  end

  defp account_status_update_attrs(%UserEnforcement{
         action: "permanent_ban",
         reason_code: reason_code,
         starts_at: starts_at
       }) do
    %{
      account_status: "banned",
      account_status_reason_code: reason_code,
      account_restricted_at: starts_at,
      account_restricted_until: nil,
      account_banned_at: starts_at
    }
  end

  defp driver_update_attrs(%UserEnforcement{action: "temporary_suspension", starts_at: starts_at}) do
    %{
      "account_status" => "suspended",
      "is_available" => false,
      "suspended_at" => starts_at,
      "last_seen_at" => starts_at
    }
  end

  defp driver_update_attrs(%UserEnforcement{action: "permanent_ban", starts_at: starts_at}) do
    %{
      "account_status" => "deactivated",
      "is_available" => false,
      "suspended_at" => starts_at,
      "last_seen_at" => starts_at
    }
  end

  defp driver_update_attrs(_enforcement), do: nil

  defp resolve_due_within_hours(attrs) do
    value = Query.get_value(attrs, :due_within_hours)

    case value do
      nil ->
        {:ok, @default_due_within_hours}

      parsed when is_integer(parsed) and parsed >= 1 and parsed <= @max_due_within_hours ->
        {:ok, parsed}

      binary when is_binary(binary) ->
        case Integer.parse(String.trim(binary)) do
          {parsed, ""} when parsed >= 1 and parsed <= @max_due_within_hours -> {:ok, parsed}
          _ -> {:error, :invalid_due_within_hours}
        end

      _ ->
        {:error, :invalid_due_within_hours}
    end
  end

  defp unwrap_or_rollback({:ok, value}), do: value
  defp unwrap_or_rollback({:error, changeset}), do: Repo.rollback(changeset)
end
