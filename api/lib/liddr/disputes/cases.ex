defmodule Liddr.Disputes.Cases do
  import Ecto.Query

  alias Liddr.Disputes.Compensations
  alias Liddr.Disputes.CasesSupport
  alias Liddr.Moderation
  alias Liddr.Moderation.Query
  alias Liddr.Moderation.Report
  alias Liddr.Repo
  alias Liddr.Rides.Ride

  @dispute_type_map %{
    "fare_dispute" => %{category_slug: "payment_dispute", incident_type: "payment"},
    "driver_not_arrived" => %{
      category_slug: "cancellation_or_no_show_abuse",
      incident_type: "conduct"
    },
    "wrong_route" => %{category_slug: "payment_dispute", incident_type: "payment"},
    "safety_incident" => %{category_slug: "harassment_or_abuse", incident_type: "safety"},
    "lost_item" => %{category_slug: "theft_or_lost_property_misconduct", incident_type: "conduct"},
    "payment_not_received" => %{category_slug: "payment_dispute", incident_type: "payment"},
    "wrong_driver" => %{category_slug: "account_sharing_or_impersonation", incident_type: "fraud"},
    "app_error" => %{category_slug: "other", incident_type: "other"},
    "other" => %{category_slug: "other", incident_type: "other"}
  }

  @resolve_outcomes ~w(dismissed no_action refund_full refund_partial credit_note escalate)

  def submit_for_ride(requester_user_id, attrs) do
    with {:ok, ride_id} <-
           parse_positive_integer(Query.get_value(attrs, :ride_id), :invalid_ride_id),
         %Ride{} = ride <- Repo.get(Ride, ride_id),
         {:ok, reported_user_id} <- resolve_reported_user_id(ride, requester_user_id),
         {:ok, dispute_type} <- fetch_dispute_type(attrs),
         {:ok, mapping} <- fetch_dispute_mapping(dispute_type),
         {:ok, report_attrs} <-
           build_report_attrs(
             attrs,
             ride,
             requester_user_id,
             reported_user_id,
             dispute_type,
             mapping
           ) do
      Moderation.submit_report(report_attrs)
    else
      nil -> {:error, :ride_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def list_for_user(user_id, attrs \\ %{}) do
    Report
    |> base_dispute_query()
    |> apply_user_scope(user_id, attrs)
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.apply_sort(
      attrs,
      %{"inserted_at" => :inserted_at, "status" => :status},
      :inserted_at
    )
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def list_for_ops(attrs \\ %{}) do
    Report
    |> base_dispute_query()
    |> Query.maybe_filter_equals(:status, Query.get_value(attrs, :status))
    |> Query.maybe_filter_equals(
      :reported_user_id,
      Query.parse_integer(Query.get_value(attrs, :reported_user_id))
    )
    |> Query.maybe_filter_equals(
      :reporter_user_id,
      Query.parse_integer(Query.get_value(attrs, :reporter_user_id))
    )
    |> Query.apply_sort(
      attrs,
      %{"inserted_at" => :inserted_at, "status" => :status},
      :inserted_at
    )
    |> Query.apply_pagination(attrs)
    |> Repo.all()
  end

  def resolve_for_ops(report_id, reviewer_user_id, attrs \\ %{}) do
    with {:ok, parsed_report_id} <-
           CasesSupport.parse_positive_integer(report_id, :invalid_report_id),
         %Report{} = report <- fetch_dispute_report(parsed_report_id),
         {:ok, outcome} <- fetch_resolution_outcome(attrs),
         {:ok, decision} <- moderation_decision_for_outcome(outcome),
         {:ok, review_attrs} <- CasesSupport.build_review_attrs(attrs, outcome, decision) do
      Repo.transaction(fn ->
        with {:ok, payload} <-
               Moderation.review_report(report.id, review_attrs, reviewer_user_id),
             {:ok, compensation} <-
               Compensations.create_for_outcome(
                 payload.report,
                 outcome,
                 attrs,
                 reviewer_user_id
               ) do
          payload
          |> Map.put(:resolution_outcome, outcome)
          |> Map.put(:compensation, compensation)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> Query.unwrap_transaction_result()
    else
      nil ->
        {:error, :dispute_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp base_dispute_query(queryable) do
    from r in queryable,
      where:
        r.context_type == "ride" and
          fragment("? ->> 'dispute_type' IS NOT NULL", r.metadata)
  end

  defp apply_user_scope(query, user_id, attrs) do
    case attrs |> Query.get_value(:scope) |> Query.normalize_text() do
      "opened" ->
        from r in query, where: r.reporter_user_id == ^user_id

      "received" ->
        from r in query, where: ^CasesSupport.visible_to_reported_user(user_id)

      _ ->
        received = CasesSupport.visible_to_reported_user(user_id)
        participant = dynamic([r], r.reporter_user_id == ^user_id or ^received)
        from r in query, where: ^participant
    end
  end

  defp fetch_dispute_report(report_id) do
    Repo.one(
      from r in Report,
        where:
          r.id == ^report_id and r.context_type == "ride" and
            fragment("? ->> 'dispute_type' IS NOT NULL", r.metadata)
    )
  end

  defp build_report_attrs(attrs, ride, requester_user_id, reported_user_id, dispute_type, mapping) do
    description =
      attrs
      |> Query.get_value(:description)
      |> Query.normalize_text()

    if is_nil(description) do
      {:error, :invalid_dispute_description}
    else
      incident_at = Query.get_value(attrs, :incident_at)

      {:ok,
       %{
         "reporter_user_id" => requester_user_id,
         "reported_user_id" => reported_user_id,
         "category_slug" => mapping.category_slug,
         "description" => description,
         "source" => "in_app",
         "incident_type" => mapping.incident_type,
         "context_type" => "ride",
         "context_reference" => Integer.to_string(ride.id),
         "incident_at" => incident_at,
         "metadata" => %{
           "dispute_type" => dispute_type,
           "ride_id" => ride.id,
           "requested_resolution" => Query.get_value(attrs, :requested_resolution),
           "submitted_via" => "disputes_api_v1"
         }
       }}
    end
  end

  defp resolve_reported_user_id(%Ride{} = ride, requester_user_id) do
    cond do
      ride.rider_id == requester_user_id and is_integer(ride.driver_id) ->
        {:ok, ride.driver_id}

      ride.driver_id == requester_user_id and is_integer(ride.rider_id) ->
        {:ok, ride.rider_id}

      ride.rider_id == requester_user_id ->
        {:error, :ride_not_assigned_to_driver}

      true ->
        {:error, :ride_not_assigned_to_user}
    end
  end

  defp fetch_dispute_type(attrs) do
    dispute_type =
      attrs
      |> Query.get_value(:dispute_type)
      |> Query.normalize_text()

    if dispute_type in Map.keys(@dispute_type_map),
      do: {:ok, dispute_type},
      else: {:error, :invalid_dispute_type}
  end

  defp fetch_dispute_mapping(dispute_type) do
    case Map.get(@dispute_type_map, dispute_type) do
      nil -> {:error, :invalid_dispute_type}
      mapping -> {:ok, mapping}
    end
  end

  defp fetch_resolution_outcome(attrs) do
    outcome =
      attrs
      |> Query.get_value(:resolution_outcome)
      |> Query.normalize_text()

    if outcome in @resolve_outcomes,
      do: {:ok, outcome},
      else: {:error, :invalid_dispute_resolution_outcome}
  end

  defp moderation_decision_for_outcome("dismissed"), do: {:ok, "dismiss"}
  defp moderation_decision_for_outcome("escalate"), do: {:ok, "escalate"}

  defp moderation_decision_for_outcome(outcome) when outcome in @resolve_outcomes,
    do: {:ok, "no_action"}

  defp moderation_decision_for_outcome(_outcome),
    do: {:error, :invalid_dispute_resolution_outcome}

  defp parse_positive_integer(value, error_reason),
    do: CasesSupport.parse_positive_integer(value, error_reason)
end
