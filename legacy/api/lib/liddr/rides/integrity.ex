defmodule Liddr.Rides.Integrity do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation.UserEnforcement
  alias Liddr.Repo
  alias Liddr.Rides.Integrity.Enforcement
  alias Liddr.Rides.Integrity.Policy
  alias Liddr.Rides.RideEvent
  alias Liddr.Rides.Ride

  @default_reconciliation_limit 200
  @max_reconciliation_limit 1_000
  @ops_recent_events_limit 20

  def self_view(user_id, roles, _opts \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    window_start = Policy.rolling_window_start(now)
    roles = normalize_roles(roles)

    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        rider_chargeable_events_7d =
          if "rider" in roles,
            do: Enforcement.count_chargeable_events_7d(user.id, "rider", window_start),
            else: 0

        driver_chargeable_events_7d =
          if "driver" in roles,
            do: Enforcement.count_chargeable_events_7d(user.id, "driver", window_start),
            else: 0

        rider_reset = reset_eta_for_role(user.id, "rider", now, window_start)
        driver_reset = reset_eta_for_role(user.id, "driver", now, window_start)
        active_driver_suspension = active_driver_suspension(user.id, now)
        missed_offer_events_24h = missed_offer_events_24h(user.id, now)

        {:ok,
         %{
           user: %{
             id: user.id,
             account_status: user.account_status,
             roles: roles,
             ride_booking_mode: user.ride_booking_mode,
             ride_booking_mode_until: user.ride_booking_mode_until
           },
           policy: policy_snapshot(),
           counters: %{
             rider_chargeable_events_7d: rider_chargeable_events_7d,
             driver_chargeable_events_7d: driver_chargeable_events_7d,
             missed_offer_events_24h: missed_offer_events_24h
           },
           rider: %{
             tier:
               rider_tier(
                 user,
                 rider_chargeable_events_7d,
                 now
               ),
             reset_eta: rider_reset
           },
           driver: %{
             tier:
               driver_tier(
                 driver_chargeable_events_7d,
                 active_driver_suspension
               ),
             reset_eta: driver_reset
           }
         }}
    end
  end

  def ops_lookup_user(user_id, opts \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    window_start = Policy.rolling_window_start(now)
    recent_limit = parse_limit(get_value(opts, :recent_limit), @ops_recent_events_limit, 1, 100)

    case Repo.get(User, user_id) do
      nil ->
        {:error, :user_not_found}

      %User{} = user ->
        rider_chargeable_events_7d =
          Enforcement.count_chargeable_events_7d(user.id, "rider", window_start)

        driver_chargeable_events_7d =
          Enforcement.count_chargeable_events_7d(user.id, "driver", window_start)

        {:ok,
         %{
           user: user,
           policy: policy_snapshot(),
           prepay_mode: prepay_snapshot(user, now),
           counters: %{
             rider_chargeable_events_7d: rider_chargeable_events_7d,
             driver_chargeable_events_7d: driver_chargeable_events_7d
           },
           recent_chargeable_events:
             list_recent_chargeable_events(user.id, window_start, recent_limit)
         }}
    end
  end

  def expire_due_rider_prepay_modes(attrs \\ %{}) do
    now =
      case get_value(attrs, :now) do
        %DateTime{} = dt -> DateTime.truncate(dt, :microsecond)
        _ -> DateTime.utc_now() |> DateTime.truncate(:microsecond)
      end

    limit =
      parse_limit(
        get_value(attrs, :limit),
        @default_reconciliation_limit,
        1,
        @max_reconciliation_limit
      )

    result =
      Repo.transaction(fn ->
        due_users =
          Repo.all(
            from u in User,
              where:
                u.ride_booking_mode == "prepay_only" and not is_nil(u.ride_booking_mode_until) and
                  u.ride_booking_mode_until <= ^now,
              order_by: [asc: u.ride_booking_mode_until, asc: u.id],
              limit: ^limit,
              lock: "FOR UPDATE"
          )

        Enum.map(due_users, fn user ->
          user
          |> User.ride_booking_mode_changeset(%{
            "ride_booking_mode" => "normal",
            "ride_booking_mode_until" => nil
          })
          |> Repo.update()
          |> case do
            {:ok, _updated_user} ->
              %{
                user_id: user.id,
                previous_mode: "prepay_only",
                previous_mode_until: user.ride_booking_mode_until,
                mode: "normal",
                reconciled_at: now
              }

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
      end)

    case result do
      {:ok, reconciled} -> {:ok, reconciled}
      {:error, reason} -> {:error, reason}
    end
  end

  def default_reconciliation_limit, do: @default_reconciliation_limit
  def max_reconciliation_limit, do: @max_reconciliation_limit

  defp rider_tier(user, rider_chargeable_events_7d, now) do
    prepay_active =
      user.ride_booking_mode == "prepay_only" and
        is_struct(user.ride_booking_mode_until, DateTime) and
        DateTime.compare(user.ride_booking_mode_until, now) == :gt

    cond do
      prepay_active ->
        %{
          level: "prepay_only",
          active: true,
          until: user.ride_booking_mode_until
        }

      rider_chargeable_events_7d >= Policy.rider_chargeable_escalation_threshold() ->
        %{level: "high_risk", active: false}

      rider_chargeable_events_7d >= Policy.rider_chargeable_threshold() ->
        %{level: "at_risk", active: false}

      true ->
        %{level: "normal", active: false}
    end
  end

  defp driver_tier(_driver_chargeable_events_7d, %UserEnforcement{} = suspension) do
    %{
      level: "temporary_suspension",
      active: true,
      until: suspension.ends_at
    }
  end

  defp driver_tier(driver_chargeable_events_7d, nil) do
    cond do
      driver_chargeable_events_7d >= Policy.driver_chargeable_escalation_threshold() ->
        %{level: "high_risk", active: false}

      driver_chargeable_events_7d >= Policy.driver_chargeable_threshold() ->
        %{level: "at_risk", active: false}

      true ->
        %{level: "normal", active: false}
    end
  end

  defp active_driver_suspension(user_id, now) do
    Repo.one(
      from ue in UserEnforcement,
        where:
          ue.user_id == ^user_id and ue.scope == "rides" and ue.action == "temporary_suspension" and
            ue.status == "active" and not is_nil(ue.ends_at) and ue.ends_at > ^now,
        order_by: [desc: ue.ends_at, desc: ue.id],
        limit: 1
    )
  end

  defp missed_offer_events_24h(user_id, now) do
    window_start = DateTime.add(now, -86_400, :second)
    subject_user_id_text = Integer.to_string(user_id)

    Repo.aggregate(
      from(e in RideEvent,
        where: e.event_type == "offer_missed" and e.occurred_at >= ^window_start,
        where: fragment("?->>'driver_id' = ?", e.payload, ^subject_user_id_text)
      ),
      :count,
      :id
    )
  end

  defp reset_eta_for_role(user_id, subject_role, now, window_start) do
    subject_user_id_text = Integer.to_string(user_id)

    earliest =
      Repo.one(
        from r in Ride,
          where: r.status == "cancelled" and r.cancelled_at >= ^window_start,
          where:
            fragment("?->'integrity'->>'chargeable' = 'true'", r.metadata) and
              fragment("?->'integrity'->>'subject_role' = ?", r.metadata, ^subject_role) and
              fragment(
                "?->'integrity'->>'subject_user_id' = ?",
                r.metadata,
                ^subject_user_id_text
              ),
          order_by: [asc: r.cancelled_at, asc: r.id],
          limit: 1,
          select: r.cancelled_at
      )

    if is_struct(earliest, DateTime) do
      reset_at = DateTime.add(earliest, Policy.rolling_window_days() * 86_400, :second)

      %{
        reset_at: reset_at,
        seconds_remaining: max(DateTime.diff(reset_at, now, :second), 0)
      }
    else
      nil
    end
  end

  defp normalize_roles(roles) when is_list(roles), do: Enum.uniq(roles)
  defp normalize_roles(_roles), do: []

  defp policy_snapshot do
    %{
      rolling_window_days: Policy.rolling_window_days(),
      rider_chargeable_threshold: Policy.rider_chargeable_threshold(),
      rider_chargeable_escalation_threshold: Policy.rider_chargeable_escalation_threshold(),
      rider_prepay_only_days: Policy.rider_prepay_only_days(),
      rider_prepay_only_escalation_days: Policy.rider_prepay_only_escalation_days(),
      driver_chargeable_threshold: Policy.driver_chargeable_threshold(),
      driver_chargeable_escalation_threshold: Policy.driver_chargeable_escalation_threshold(),
      driver_temp_suspension_days: Policy.driver_temp_suspension_days(),
      driver_temp_suspension_escalation_days: Policy.driver_temp_suspension_escalation_days(),
      rider_prepay_payment_mode: Policy.rider_prepay_payment_mode(),
      pickup_auto_reassign_enabled: Policy.pickup_auto_reassign_enabled(),
      pickup_auto_reassign_after_seconds: Policy.pickup_auto_reassign_after_seconds(),
      pickup_auto_cancel_enabled: Policy.pickup_auto_cancel_enabled(),
      pickup_auto_cancel_after_seconds: Policy.pickup_auto_cancel_after_seconds(),
      pickup_auto_cancel_min_reassign_count: Policy.pickup_auto_cancel_min_reassign_count()
    }
  end

  defp prepay_snapshot(user, now) do
    active =
      user.ride_booking_mode == "prepay_only" and
        is_struct(user.ride_booking_mode_until, DateTime) and
        DateTime.compare(user.ride_booking_mode_until, now) == :gt

    seconds_remaining =
      if active do
        DateTime.diff(user.ride_booking_mode_until, now, :second)
      else
        0
      end

    %{
      mode: user.ride_booking_mode || "normal",
      mode_until: user.ride_booking_mode_until,
      active: active,
      seconds_remaining: seconds_remaining
    }
  end

  defp list_recent_chargeable_events(user_id, window_start, limit) do
    subject_user_id_text = Integer.to_string(user_id)

    Repo.all(
      from r in Ride,
        where: r.status == "cancelled" and r.cancelled_at >= ^window_start,
        where:
          fragment("?->'integrity'->>'chargeable' = 'true'", r.metadata) and
            fragment("?->'integrity'->>'subject_user_id' = ?", r.metadata, ^subject_user_id_text),
        order_by: [desc: r.cancelled_at, desc: r.id],
        limit: ^limit
    )
    |> Enum.map(fn ride ->
      integrity =
        case ride.metadata do
          %{"integrity" => %{} = payload} -> payload
          _ -> %{}
        end

      %{
        ride_id: ride.id,
        status: ride.status,
        cancelled_at: ride.cancelled_at,
        cancellation_reason_code: ride.cancellation_reason_code,
        subject_role: Map.get(integrity, "subject_role"),
        violation_type: Map.get(integrity, "violation_type"),
        waiver_code: Map.get(integrity, "waiver_code")
      }
    end)
  end

  defp parse_limit(nil, default, _min, _max), do: default

  defp parse_limit(value, default, min, max) when is_integer(value) do
    if value < min or value > max, do: default, else: value
  end

  defp parse_limit(value, default, min, max) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parse_limit(parsed, default, min, max)
      _ -> default
    end
  end

  defp parse_limit(_value, default, _min, _max), do: default

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))

  defp get_value(_attrs, _key), do: nil
end
