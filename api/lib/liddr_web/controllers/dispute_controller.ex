defmodule LiddrWeb.DisputeController do
  use LiddrWeb, :controller

  alias Liddr.Disputes
  alias Liddr.Observability.ModerationEvents
  alias LiddrWeb.DisputeErrors
  alias LiddrWeb.DisputePayloads
  alias LiddrWeb.Idempotency

  def create(conn, params) do
    requester_user_id = conn.assigns.current_user.id
    payload = Map.put(params, "requester_user_id", requester_user_id)

    Idempotency.execute(
      conn,
      "dispute.create:#{requester_user_id}",
      payload,
      fn ->
        with :ok <- Disputes.enforce_submit_rate_limit(requester_user_id),
             {:ok, report} <- Disputes.submit_for_ride(requester_user_id, payload) do
          ModerationEvents.dispute_create_success(%{
            reporter_user_id: requester_user_id,
            dispute_type: metadata_value(report.metadata, "dispute_type")
          })

          {:ok, 201, %{data: DisputePayloads.report(report)}}
        else
          {:error, reason} -> {:error, reason}
        end
      end,
      &DisputeErrors.render/2
    )
  end

  def index(conn, params) do
    user_id = conn.assigns.current_user.id
    reports = Disputes.list_for_user(user_id, params) |> Enum.map(&DisputePayloads.report/1)
    json(conn, %{data: %{disputes: reports}})
  end

  def compensations(conn, params) do
    user_id = conn.assigns.current_user.id

    compensations =
      Disputes.list_compensations_for_user(user_id, params)
      |> Enum.map(&DisputePayloads.compensation/1)

    json(conn, %{data: %{compensations: compensations}})
  end

  defp metadata_value(%{} = metadata, key) when is_binary(key) do
    Map.get(metadata, key)
  end

  defp metadata_value(_metadata, _key), do: nil
end
