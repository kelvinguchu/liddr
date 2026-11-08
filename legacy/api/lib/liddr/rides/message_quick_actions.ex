defmodule Liddr.Rides.MessageQuickActions do
  @moduledoc false

  @default_locale "en"
  @labels %{
    "arrived" => %{"en" => "I have arrived", "sw" => "Nimefika"},
    "on_my_way" => %{"en" => "I am on my way", "sw" => "Niko njiani"},
    "running_late" => %{"en" => "I am running late", "sw" => "Nachelewa"},
    "cant_find_you" => %{"en" => "I cannot find you", "sw" => "Siwezi kukupata"},
    "call_me" => %{"en" => "Please call me", "sw" => "Tafadhali nipigie simu"}
  }

  def codes, do: Map.keys(@labels)

  def valid_code?(code) when is_binary(code), do: Map.has_key?(@labels, code)
  def valid_code?(_code), do: false

  def body_for_code(code) when is_binary(code) do
    case Map.get(@labels, code) do
      %{} = localized -> Map.fetch!(localized, @default_locale)
      _ -> nil
    end
  end

  def payload(code, locale \\ nil) do
    with true <- valid_code?(code),
         locale <- resolve_locale(locale),
         %{} = labels <- Map.get(@labels, code) do
      %{
        code: code,
        label_default: Map.fetch!(labels, @default_locale),
        label_localized: Map.get(labels, locale, Map.fetch!(labels, @default_locale)),
        locale: locale
      }
    else
      _ -> nil
    end
  end

  def resolve_locale(value) do
    value
    |> normalize_locale()
    |> case do
      locale when locale in ["en", "sw"] -> locale
      _ -> @default_locale
    end
  end

  defp normalize_locale(nil), do: nil

  defp normalize_locale(value) do
    value
    |> to_string()
    |> String.split(",", parts: 2)
    |> hd()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.trim()
    |> String.downcase()
    |> String.split("-", parts: 2)
    |> hd()
  end
end
