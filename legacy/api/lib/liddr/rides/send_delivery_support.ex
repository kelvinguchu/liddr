defmodule Liddr.Rides.SendDeliverySupport do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Repo
  alias Liddr.Rides.Execution.Shared
  alias Liddr.Rides.Ride
  alias Liddr.Rides.SendDelivery
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @send_slug "send"
  @confirmation_wait_default_seconds 600
  @confirmation_token_ttl_default_seconds 1800

  def required_text(attrs, key, error_code) do
    case attrs |> PaymentUtils.get_value(key) |> PaymentUtils.normalize_text() do
      nil -> {:error, error_code}
      value -> {:ok, value}
    end
  end

  def ensure_send_ride!(%Ride{} = ride) do
    if send_ride?(ride), do: :ok, else: Repo.rollback(:send_ride_required)
  end

  def send_ride?(%Ride{} = ride) do
    Repo.exists?(
      from vc in VehicleCategory,
        where: vc.id == ^ride.vehicle_category_id and vc.slug == @send_slug
    )
  end

  def ensure_delivery_for_ride!(%Ride{} = ride, now) do
    Repo.get_by(SendDelivery, ride_id: ride.id) || create_delivery_from_ride!(ride, now)
  end

  def update_delivery!(delivery, attrs) do
    delivery
    |> SendDelivery.create_changeset(attrs)
    |> Repo.update()
    |> Shared.unwrap_or_rollback()
  end

  def completion_wait_elapsed?(delivery, now) do
    DateTime.diff(now, delivery.dropoff_proof_captured_at, :second) >= confirmation_wait_seconds()
  end

  def confirmation_wait_seconds do
    System.get_env("SEND_RECIPIENT_CONFIRM_WAIT_SECONDS")
    |> PaymentUtils.parse_integer(@confirmation_wait_default_seconds)
    |> max(60)
    |> min(7_200)
  end

  def confirmation_token_ttl_seconds do
    System.get_env("SEND_RECIPIENT_CONFIRM_TOKEN_TTL_SECONDS")
    |> PaymentUtils.parse_integer(@confirmation_token_ttl_default_seconds)
    |> max(300)
    |> min(86_400)
  end

  def recipient_confirmation_url(token) do
    base_url =
      System.get_env("SEND_RECIPIENT_CONFIRM_BASE_URL") ||
        "http://localhost:4000/api"

    String.trim_trailing(base_url, "/") <> "/send/recipient-confirmations/" <> URI.encode(token)
  end

  defp create_delivery_from_ride!(ride, now) do
    delivery = ride.metadata |> Map.get("delivery", %{}) |> normalize_map()

    attrs = %{
      "ride_id" => ride.id,
      "sender_name" => PaymentUtils.get_value(delivery, :sender_name),
      "sender_phone" => PaymentUtils.get_value(delivery, :sender_phone),
      "recipient_name" => PaymentUtils.get_value(delivery, :recipient_name),
      "recipient_phone" => PaymentUtils.get_value(delivery, :recipient_phone),
      "item_description" => PaymentUtils.get_value(delivery, :item_description),
      "item_size" => normalize_enum(PaymentUtils.get_value(delivery, :item_size), "small"),
      "payer" => normalize_enum(PaymentUtils.get_value(delivery, :payer), "sender"),
      "payment_timing" =>
        normalize_enum(PaymentUtils.get_value(delivery, :payment_timing), "after"),
      "item_value_kes" => parse_decimal(PaymentUtils.get_value(delivery, :item_value_kes)),
      "special_instructions" => PaymentUtils.get_value(delivery, :special_instructions),
      "liability_acknowledged" =>
        parse_bool(PaymentUtils.get_value(delivery, :liability_acknowledged), false),
      "prohibited_item_warnings" =>
        normalize_warnings(PaymentUtils.get_value(delivery, :prohibited_item_warnings)),
      "delivery_status" =>
        if(ride.status == "in_progress", do: "in_transit", else: "pending_pickup"),
      "inserted_at" => now,
      "updated_at" => now
    }

    %SendDelivery{}
    |> SendDelivery.create_changeset(attrs)
    |> Repo.insert()
    |> Shared.unwrap_or_rollback()
  end

  defp normalize_map(%{} = map), do: map
  defp normalize_map(_value), do: %{}

  defp normalize_warnings(warnings) when is_list(warnings), do: %{"items" => warnings}
  defp normalize_warnings(%{} = warnings), do: warnings
  defp normalize_warnings(_warnings), do: %{}

  defp normalize_enum(value, default) do
    value
    |> PaymentUtils.normalize_text()
    |> case do
      nil -> default
      normalized -> String.downcase(normalized)
    end
  end

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%D{} = value), do: value
  defp parse_decimal(value) when is_integer(value), do: D.new(value)
  defp parse_decimal(value) when is_float(value), do: D.from_float(value) |> D.round(2)

  defp parse_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(_value), do: nil

  defp parse_bool(value, default) do
    case value do
      value when value in [true, "true", "1", "yes", "on"] -> true
      value when value in [false, "false", "0", "no", "off"] -> false
      _ -> default
    end
  end
end
