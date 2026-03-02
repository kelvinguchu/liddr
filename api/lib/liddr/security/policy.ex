defmodule Liddr.Security.Policy do
  @moduledoc false

  import Bitwise
  require Logger

  @default_mode :observe
  @trusted_ip_header_keys ["cf-connecting-ip", "x-real-ip", "x-forwarded-for"]

  def security_mode do
    case normalize_text(System.get_env("SECURITY_MODE")) do
      "enforce" -> :enforce
      "observe" -> :observe
      _ -> @default_mode
    end
  end

  def enforce_ip_allowlist(conn, env_key, scope) do
    allowlist = parse_allowlist(System.get_env(env_key))
    mode = security_mode()
    client_ip = request_client_ip(conn)

    decision =
      cond do
        allowlist == [] -> :allow
        is_nil(client_ip) -> :unknown
        ip_allowed?(client_ip, allowlist) -> :allow
        true -> :deny
      end

    case {mode, decision} do
      {_mode, :allow} ->
        :ok

      {:observe, outcome} when outcome in [:deny, :unknown] ->
        Logger.warning(
          "[security.observe] request allowed but would be blocked",
          security_scope: scope,
          allowlist_env: env_key,
          client_ip: client_ip,
          outcome: outcome
        )

        :ok

      {:enforce, :deny} ->
        {:error, :ip_not_allowed}

      {:enforce, :unknown} ->
        {:error, :client_ip_unresolved}
    end
  end

  def request_client_ip(conn) do
    if trust_proxy_headers?() do
      header_ip(conn) || remote_ip_string(conn.remote_ip)
    else
      remote_ip_string(conn.remote_ip)
    end
  end

  def parse_allowlist(raw_value) do
    raw_value
    |> normalize_text()
    |> case do
      nil ->
        []

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reduce([], fn entry, acc ->
          case parse_allowlist_entry(entry) do
            {:ok, parsed} ->
              [parsed | acc]

            :error ->
              Logger.warning("[security] ignored invalid IP allowlist entry", entry: entry)
              acc
          end
        end)
        |> Enum.reverse()
    end
  end

  def ip_allowed?(client_ip, allowlist) when is_list(allowlist) do
    with {:ok, tuple} <- parse_ip_tuple(client_ip),
         {:ok, client_int, bits} <- ip_to_integer(tuple) do
      Enum.any?(allowlist, fn {network_int, prefix, network_bits} ->
        bits == network_bits and within_network?(client_int, network_int, prefix, bits)
      end)
    else
      _ -> false
    end
  end

  def ip_allowed?(_client_ip, _allowlist), do: false

  defp parse_allowlist_entry(entry) do
    case String.split(entry, "/", parts: 2) do
      [ip_text] ->
        with {:ok, tuple} <- parse_ip_tuple(ip_text),
             {:ok, ip_int, bits} <- ip_to_integer(tuple) do
          {:ok, {ip_int, bits, bits}}
        end

      [ip_text, prefix_text] ->
        with {:ok, tuple} <- parse_ip_tuple(ip_text),
             {:ok, ip_int, bits} <- ip_to_integer(tuple),
             {:ok, prefix} <- parse_prefix(prefix_text, bits) do
          {:ok, {ip_int, prefix, bits}}
        end

      _ ->
        :error
    end
  end

  defp parse_prefix(prefix_text, bits) do
    case Integer.parse(String.trim(prefix_text)) do
      {prefix, ""} when prefix >= 0 and prefix <= bits -> {:ok, prefix}
      _ -> :error
    end
  end

  defp within_network?(_client_int, _network_int, 0, _bits), do: true

  defp within_network?(client_int, network_int, prefix, bits) do
    shift = bits - prefix
    client_int >>> shift == network_int >>> shift
  end

  defp parse_ip_tuple(value) when is_binary(value) do
    case :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, tuple} -> {:ok, tuple}
      {:error, _reason} -> :error
    end
  end

  defp parse_ip_tuple(_value), do: :error

  defp ip_to_integer({a, b, c, d}) do
    {:ok, (a <<< 24) + (b <<< 16) + (c <<< 8) + d, 32}
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    {:ok,
     Enum.reduce([a, b, c, d, e, f, g, h], 0, fn segment, acc ->
       (acc <<< 16) + segment
     end), 128}
  end

  defp ip_to_integer(_tuple), do: :error

  defp header_ip(conn) do
    Enum.find_value(@trusted_ip_header_keys, fn header ->
      conn
      |> Plug.Conn.get_req_header(header)
      |> List.first()
      |> extract_first_header_ip()
    end)
  end

  defp extract_first_header_ip(nil), do: nil

  defp extract_first_header_ip(header_value) do
    header_value
    |> String.split(",", trim: true)
    |> List.first()
    |> normalize_text()
    |> case do
      nil ->
        nil

      ip ->
        case parse_ip_tuple(ip) do
          {:ok, tuple} -> tuple |> :inet.ntoa() |> to_string()
          :error -> nil
        end
    end
  end

  defp remote_ip_string(nil), do: nil

  defp remote_ip_string(tuple) when is_tuple(tuple) do
    tuple
    |> :inet.ntoa()
    |> to_string()
  end

  defp remote_ip_string(_other), do: nil

  defp trust_proxy_headers? do
    case normalize_text(System.get_env("SECURITY_TRUST_PROXY_HEADERS")) do
      "1" -> true
      "true" -> true
      "yes" -> true
      _ -> false
    end
  end

  defp normalize_text(nil), do: nil

  defp normalize_text(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      parsed -> String.downcase(parsed)
    end
  end

  defp normalize_text(value), do: value |> to_string() |> normalize_text()
end
