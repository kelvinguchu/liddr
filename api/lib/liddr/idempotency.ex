defmodule Liddr.Idempotency do
  import Ecto.Query

  alias Liddr.Idempotency.Request
  alias Liddr.Repo

  @type claim ::
          %{
            id: integer(),
            user_id: integer(),
            operation: String.t(),
            idempotency_key: String.t(),
            request_hash: String.t()
          }

  @stale_claim_seconds 300

  def claim(user_id, operation, idempotency_key, payload) do
    with {:ok, normalized_key} <- normalize_key(idempotency_key),
         {:ok, normalized_operation} <- normalize_operation(operation) do
      request_hash = request_hash(payload)

      attrs = %{
        user_id: user_id,
        operation: normalized_operation,
        idempotency_key: normalized_key,
        request_hash: request_hash
      }

      changeset = Request.create_changeset(%Request{}, attrs)

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:user_id, :operation, :idempotency_key]
           ) do
        {:ok, %Request{id: id}} when is_integer(id) ->
          {:proceed,
           %{
             id: id,
             user_id: user_id,
             operation: normalized_operation,
             idempotency_key: normalized_key,
             request_hash: request_hash
           }}

        {:ok, _} ->
          retry_claim = fn -> claim(user_id, operation, idempotency_key, payload) end

          resolve_existing(
            user_id,
            normalized_operation,
            normalized_key,
            request_hash,
            retry_claim
          )

        {:error, _changeset} ->
          {:error, :invalid_idempotency_key}
      end
    else
      :bypass -> :bypass
      {:error, reason} -> {:error, reason}
    end
  end

  def complete(%{id: id}, status, body) when is_integer(id) do
    with %Request{} = request <- Repo.get(Request, id),
         normalized_body <- normalize_response_body(body),
         completed_at <- DateTime.utc_now() |> DateTime.truncate(:microsecond),
         {:ok, _updated} <-
           request
           |> Request.complete_changeset(%{
             response_status: status,
             response_body: normalized_body,
             completed_at: completed_at
           })
           |> Repo.update() do
      :ok
    else
      _ -> :ok
    end
  end

  def complete(_claim, _status, _body), do: :ok

  def abandon(%{id: id}) when is_integer(id) do
    case Repo.get(Request, id) do
      %Request{} = request ->
        _ = Repo.delete(request)
        :ok

      _ ->
        :ok
    end
  end

  def abandon(_claim), do: :ok

  defp resolve_existing(user_id, operation, idempotency_key, request_hash, retry_claim) do
    existing =
      Repo.one(
        from r in Request,
          where:
            r.user_id == ^user_id and r.operation == ^operation and
              r.idempotency_key == ^idempotency_key,
          limit: 1
      )

    cond do
      is_nil(existing) ->
        {:error, :idempotency_conflict}

      existing.request_hash != request_hash ->
        {:error, :idempotency_payload_mismatch}

      is_integer(existing.response_status) and is_map(existing.response_body) ->
        {:replay, %{status: existing.response_status, body: existing.response_body}}

      release_stale_claim(existing) ->
        retry_claim.()

      true ->
        {:error, :idempotency_in_progress}
    end
  end

  defp release_stale_claim(%Request{id: id}) do
    cutoff = DateTime.utc_now() |> DateTime.add(-@stale_claim_seconds, :second)

    {released, _} =
      Repo.delete_all(
        from r in Request,
          where: r.id == ^id and is_nil(r.response_status) and r.inserted_at < ^cutoff
      )

    released == 1
  end

  defp normalize_response_body(body) when is_map(body) do
    case Jason.encode(body) do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, normalized} when is_map(normalized) -> normalized
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp normalize_response_body(_body), do: %{}

  defp normalize_key(nil), do: :bypass

  defp normalize_key(idempotency_key) when is_binary(idempotency_key) do
    case String.trim(idempotency_key) do
      "" -> :bypass
      value when byte_size(value) >= 8 and byte_size(value) <= 120 -> {:ok, value}
      _ -> {:error, :invalid_idempotency_key}
    end
  end

  defp normalize_key(_idempotency_key), do: {:error, :invalid_idempotency_key}

  defp normalize_operation(operation) when is_binary(operation) do
    case String.trim(operation) do
      "" -> {:error, :invalid_idempotency_operation}
      value when byte_size(value) <= 120 -> {:ok, value}
      _ -> {:error, :invalid_idempotency_operation}
    end
  end

  defp normalize_operation(_operation), do: {:error, :invalid_idempotency_operation}

  defp request_hash(payload) do
    payload
    |> canonicalize()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {to_string(key), canonicalize(nested)} end)
    |> Enum.sort_by(fn {key, _nested} -> key end)
  end

  defp canonicalize(value) when is_list(value), do: Enum.map(value, &canonicalize/1)
  defp canonicalize(value), do: value
end
