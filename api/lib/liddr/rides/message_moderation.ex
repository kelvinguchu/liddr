defmodule Liddr.Rides.MessageModeration do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Moderation
  alias Liddr.Moderation.Report
  alias Liddr.Repo
  alias Liddr.Rides.MessageAbuseEscalation
  alias Liddr.Rides.Events
  alias Liddr.Rides.Messages
  alias Liddr.Rides.Notifications
  alias Liddr.Rides.RideMessage
  alias Liddr.Subscriptions.PaymentUtils

  @message_abuse_flag_threshold 2
  @max_report_ids 20
  def ensure_can_send(user_id), do: MessageAbuseEscalation.ensure_can_send(user_id)

  def hide_for_user(user_id, ride_id, message_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- Messages.fetch_participant_ride(user_id, ride_id),
         {:ok, message} <- Messages.fetch_message_for_update(ride.id, message_id),
         :ok <- ensure_participant_message(message, user_id),
         {:ok, updated} <- hide_message_for_user(message, user_id, now) do
      {:ok, %{ride: ride, message: updated}}
    end
  end

  def report_for_user(user_id, ride_id, message_id, attrs \\ %{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, ride} <- Messages.fetch_participant_ride(user_id, ride_id) do
      Repo.transaction(fn ->
        message =
          Messages.fetch_message_for_update(ride.id, message_id)
          |> unwrap_or_rollback()

        ensure_report_target!(message, user_id)

        report_attrs =
          build_report_attrs(user_id, ride.id, message, attrs)
          |> unwrap_or_rollback()

        report = Moderation.submit_report(report_attrs) |> unwrap_or_rollback()
        report_count = report_count_for_message(message.id)

        escalation =
          MessageAbuseEscalation.maybe_auto_escalate!(message.sender_user_id, report.id, now)

        updated_message =
          hide_and_flag_message!(message, user_id, report, report_count, now)

        _ =
          Events.record_event(ride.id, "ride_message_reported", now,
            actor_user_id: user_id,
            payload: %{
              "message_id" => message.id,
              "report_id" => report.id,
              "report_count" => report_count,
              "abuse_flagged" => report_count >= @message_abuse_flag_threshold,
              "auto_escalation" => escalation
            }
          )
          |> unwrap_or_rollback()

        _ =
          queue_report_notifications(
            ride.id,
            user_id,
            message.sender_user_id,
            message.id,
            escalation,
            now
          )

        %{ride: ride, message: updated_message, report: report, escalation: escalation}
      end)
      |> unwrap_transaction()
    end
  end

  defp ensure_report_target!(%RideMessage{sender_user_id: sender_user_id}, user_id)
       when sender_user_id == user_id,
       do: Repo.rollback(:ride_message_self_report_not_allowed)

  defp ensure_report_target!(_message, _user_id), do: :ok

  defp ensure_participant_message(%RideMessage{sender_user_id: user_id}, user_id), do: :ok
  defp ensure_participant_message(%RideMessage{recipient_user_id: user_id}, user_id), do: :ok
  defp ensure_participant_message(_message, _user_id), do: {:error, :ride_message_forbidden}

  defp build_report_attrs(user_id, ride_id, message, attrs) do
    description = resolve_description(attrs, message)

    if is_nil(description) do
      {:error, :invalid_ride_message_report_description}
    else
      {:ok,
       %{
         "reporter_user_id" => user_id,
         "reported_user_id" => message.sender_user_id,
         "reported_driver_id" => reported_driver_id(message),
         "category_slug" => PaymentUtils.get_value(attrs, :category_slug),
         "category_id" => PaymentUtils.get_value(attrs, :category_id),
         "description" => description,
         "source" => "in_app",
         "incident_type" => "conduct",
         "context_type" => "ride",
         "context_reference" => context_reference(message.id),
         "incident_at" => message.inserted_at,
         "metadata" => report_metadata(ride_id, message, attrs)
       }}
    end
  end

  defp reported_driver_id(%RideMessage{sender_role: "driver", sender_user_id: sender_user_id}),
    do: sender_user_id

  defp reported_driver_id(_message), do: nil

  defp resolve_description(attrs, message) do
    attrs
    |> PaymentUtils.get_value(:description)
    |> normalize_text()
    |> case do
      nil -> "Reported ride message: #{String.slice(message.body || "", 0, 180)}"
      value -> value
    end
  end

  defp report_metadata(ride_id, message, attrs) do
    %{
      "ride_id" => ride_id,
      "ride_message_id" => message.id,
      "message_type" => message.message_type,
      "sender_role" => message.sender_role,
      "quick_action_code" => get_in(message.metadata || %{}, ["quick_action_code"]),
      "client_metadata" => PaymentUtils.get_value(attrs, :metadata) || %{}
    }
  end

  defp context_reference(message_id), do: "ride_message:#{message_id}"

  defp report_count_for_message(message_id) do
    Repo.one(
      from r in Report,
        where: r.context_type == "ride" and r.context_reference == ^context_reference(message_id),
        select: count()
    ) || 0
  end

  defp hide_and_flag_message!(message, user_id, report, report_count, now) do
    moderation =
      message.metadata
      |> normalize_metadata()
      |> moderation_payload(report, report_count, now)

    attrs = %{
      "metadata" => put_in(normalize_metadata(message.metadata), ["moderation"], moderation)
    }

    attrs =
      if message.recipient_user_id == user_id do
        Map.put(attrs, "hidden_for_recipient_at", now)
      else
        Map.put(attrs, "hidden_for_sender_at", now)
      end

    message
    |> RideMessage.moderation_changeset(attrs)
    |> Repo.update()
    |> unwrap_or_rollback()
  end

  defp hide_message_for_user(message, user_id, now) do
    attrs =
      if message.sender_user_id == user_id do
        %{"hidden_for_sender_at" => now}
      else
        %{"hidden_for_recipient_at" => now}
      end

    message
    |> RideMessage.hide_for_user_changeset(attrs)
    |> Repo.update()
  end

  defp moderation_payload(metadata, report, report_count, now) do
    existing = Map.get(metadata, "moderation", %{})
    existing_ids = List.wrap(Map.get(existing, "report_ids")) |> Enum.filter(&is_integer/1)
    report_ids = Enum.uniq([report.id | existing_ids]) |> Enum.take(@max_report_ids)

    %{
      "reported" => true,
      "report_ids" => report_ids,
      "report_count" => report_count,
      "abuse_flagged" => report_count >= @message_abuse_flag_threshold,
      "last_report_id" => report.id,
      "last_reported_at" => now
    }
  end

  defp queue_report_notifications(
         ride_id,
         reporter_user_id,
         reported_user_id,
         message_id,
         escalation,
         now
       ) do
    _ =
      Notifications.queue_event_for_user!(
        ride_id,
        reporter_user_id,
        "ride_message_reported",
        %{"message_id" => message_id, "escalation" => escalation},
        now
      )

    if auto_restricted?(escalation) do
      _ =
        Notifications.queue_event_for_user!(
          ride_id,
          reported_user_id,
          "ride_message_communication_restricted",
          %{"message_id" => message_id, "escalation" => escalation},
          now
        )
    end

    :ok
  end

  defp auto_restricted?(%{"state" => "auto_restricted"}), do: true
  defp auto_restricted?(_escalation), do: false

  defp unwrap_or_rollback({:ok, record}), do: record
  defp unwrap_or_rollback({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_transaction({:ok, result}), do: {:ok, result}
  defp unwrap_transaction({:error, reason}), do: {:error, reason}

  defp normalize_metadata(%{} = metadata), do: metadata
  defp normalize_metadata(_metadata), do: %{}

  defp normalize_text(nil), do: nil

  defp normalize_text(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end
end
