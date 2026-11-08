defmodule Liddr.Rides.PushTokens do
  @moduledoc false

  import Ecto.Query

  alias Liddr.Repo
  alias Liddr.Rides.UserPushToken

  @platforms ~w(android ios web)
  @providers ~w(fcm)

  def register(user_id, attrs \\ %{})

  def register(user_id, attrs) when is_integer(user_id) and user_id > 0 and is_map(attrs) do
    with {:ok, token} <- fetch_required_string(attrs, :token, 8, 4096),
         {:ok, platform} <- fetch_required_enum(attrs, :platform, @platforms),
         {:ok, provider} <- fetch_optional_enum(attrs, :provider, @providers, "fcm"),
         {:ok, device_id} <- fetch_optional_string(attrs, :device_id, 0, 128) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
      metadata = normalize_metadata(get_value(attrs, :metadata))

      params = %{
        user_id: user_id,
        provider: provider,
        platform: platform,
        token: token,
        device_id: device_id,
        last_seen_at: now,
        revoked_at: nil,
        metadata: metadata
      }

      changeset = UserPushToken.create_changeset(%UserPushToken{}, params)

      case Repo.insert(changeset,
             on_conflict: [
               set: [
                 user_id: user_id,
                 provider: provider,
                 platform: platform,
                 device_id: device_id,
                 last_seen_at: now,
                 revoked_at: nil,
                 metadata: metadata,
                 updated_at: now
               ]
             ],
             conflict_target: [:token]
           ) do
        {:ok, _row} -> {:ok, Repo.get_by!(UserPushToken, token: token)}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  def register(_user_id, _attrs), do: {:error, :invalid_push_token_input}

  def revoke(user_id, attrs \\ %{})

  def revoke(user_id, attrs) when is_integer(user_id) and user_id > 0 and is_map(attrs) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    query = revoke_query(user_id, attrs)

    if is_nil(query) do
      {:error, :invalid_push_token_revoke_input}
    else
      case Repo.update_all(query, set: [revoked_at: now, updated_at: now]) do
        {count, _} when count > 0 -> :ok
        _ -> {:error, :push_token_not_found}
      end
    end
  end

  def revoke(_user_id, _attrs), do: {:error, :invalid_push_token_revoke_input}

  def list_active_tokens_for_user(user_id, provider \\ "fcm")
      when is_integer(user_id) and user_id > 0 do
    from(t in UserPushToken,
      where: t.user_id == ^user_id and t.provider == ^provider and is_nil(t.revoked_at),
      order_by: [desc: t.updated_at, desc: t.id],
      select: t.token
    )
    |> Repo.all()
    |> Enum.uniq()
  end

  def revoke_token_by_value(token) when is_binary(token) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    {count, _} =
      Repo.update_all(
        from(t in UserPushToken, where: t.token == ^String.trim(token) and is_nil(t.revoked_at)),
        set: [revoked_at: now, updated_at: now]
      )

    if count > 0, do: :ok, else: {:error, :push_token_not_found}
  end

  def revoke_token_by_value(_token), do: {:error, :invalid_push_token}

  defp revoke_query(user_id, attrs) do
    token = get_value(attrs, :token)
    device_id = get_value(attrs, :device_id)
    platform = get_value(attrs, :platform)

    cond do
      is_binary(token) and String.trim(token) != "" ->
        from(t in UserPushToken,
          where: t.user_id == ^user_id and t.token == ^String.trim(token) and is_nil(t.revoked_at)
        )

      is_binary(device_id) and String.trim(device_id) != "" ->
        normalized_platform =
          if is_binary(platform), do: String.trim(String.downcase(platform)), else: nil

        if normalized_platform in @platforms do
          from(t in UserPushToken,
            where:
              t.user_id == ^user_id and t.device_id == ^String.trim(device_id) and
                t.platform == ^normalized_platform and is_nil(t.revoked_at)
          )
        else
          from(t in UserPushToken,
            where:
              t.user_id == ^user_id and t.device_id == ^String.trim(device_id) and
                is_nil(t.revoked_at)
          )
        end

      true ->
        nil
    end
  end

  defp fetch_required_string(attrs, key, min, max) do
    case get_value(attrs, key) do
      value when is_binary(value) ->
        normalized = String.trim(value)

        if String.length(normalized) >= min and String.length(normalized) <= max do
          {:ok, normalized}
        else
          {:error, :invalid_push_token_input}
        end

      _ ->
        {:error, :invalid_push_token_input}
    end
  end

  defp fetch_optional_string(attrs, key, min, max) do
    case get_value(attrs, key) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        normalized = String.trim(value)

        cond do
          normalized == "" and min == 0 ->
            {:ok, nil}

          String.length(normalized) >= min and String.length(normalized) <= max ->
            {:ok, normalized}

          true ->
            {:error, :invalid_push_token_input}
        end

      _ ->
        {:error, :invalid_push_token_input}
    end
  end

  defp fetch_required_enum(attrs, key, allowed) do
    case get_value(attrs, key) do
      value when is_binary(value) ->
        normalized = String.trim(String.downcase(value))
        if normalized in allowed, do: {:ok, normalized}, else: {:error, :invalid_push_token_input}

      _ ->
        {:error, :invalid_push_token_input}
    end
  end

  defp fetch_optional_enum(attrs, key, allowed, default) do
    case get_value(attrs, key) do
      nil -> {:ok, default}
      value when is_binary(value) -> fetch_required_enum(%{key => value}, key, allowed)
      _ -> {:error, :invalid_push_token_input}
    end
  end

  defp normalize_metadata(%{} = value), do: value
  defp normalize_metadata(_value), do: %{}

  defp get_value(attrs, key) when is_map(attrs),
    do: Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
end
