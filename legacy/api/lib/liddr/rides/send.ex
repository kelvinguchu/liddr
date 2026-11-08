defmodule Liddr.Rides.Send do
  import Ecto.Query

  alias Decimal, as: D
  alias Liddr.Accounts.User
  alias Liddr.Auth
  alias Liddr.Rides.ProhibitedItems
  alias Liddr.Repo
  alias Liddr.Rides.Quotes
  alias Liddr.Rides.Requests
  alias Liddr.Rides.Ride
  alias Liddr.Rides.VehicleCategory
  alias Liddr.Subscriptions.PaymentUtils

  @default_history_limit 20
  @max_history_limit 100
  @item_sizes ~w(small medium large)
  @payers ~w(sender recipient)
  @payment_timings ~w(before after)

  def create_quote(rider_user_id, attrs \\ %{}) do
    with {:ok, category} <- fetch_send_category() do
      attrs
      |> Map.put("vehicle_category_id", category.id)
      |> then(&Quotes.create_quote(rider_user_id, &1))
    end
  end

  def request_delivery(rider_user_id, attrs \\ %{}) do
    with {:ok, category} <- fetch_send_category(),
         {:ok, delivery_details} <- normalize_delivery_details(rider_user_id, attrs) do
      attrs
      |> Map.put("vehicle_category_id", category.id)
      |> Map.put("product_type", "solo")
      |> then(
        &Requests.request_ride(
          rider_user_id,
          &1,
          metadata_overrides: %{"delivery" => delivery_details}
        )
      )
      |> case do
        {:ok, payload} -> {:ok, Map.put(payload, :delivery, delivery_details)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def sender_history(rider_user_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)

    rides =
      Repo.all(
        from r in Ride,
          join: vc in VehicleCategory,
          on: vc.id == r.vehicle_category_id,
          where: r.rider_id == ^rider_user_id and vc.slug == "send" and vc.is_active == true,
          order_by: [desc: r.inserted_at],
          limit: ^limit
      )

    {:ok, rides}
  end

  def courier_history(driver_user_id, attrs \\ %{}) do
    limit = resolve_limit(attrs)

    rides =
      Repo.all(
        from r in Ride,
          join: vc in VehicleCategory,
          on: vc.id == r.vehicle_category_id,
          where: r.driver_id == ^driver_user_id and vc.slug == "send" and vc.is_active == true,
          order_by: [desc: r.inserted_at],
          limit: ^limit
      )

    {:ok, rides}
  end

  defp fetch_send_category do
    case Repo.one(from vc in VehicleCategory, where: vc.slug == "send" and vc.is_active == true) do
      %VehicleCategory{} = category -> {:ok, category}
      _ -> {:error, :send_category_not_found}
    end
  end

  defp normalize_delivery_details(rider_user_id, attrs) do
    with {:ok, rider} <- fetch_rider(rider_user_id),
         {:ok, sender_name} <- required_text(attrs, :sender_name, :missing_sender_name),
         {:ok, sender_phone} <- sender_phone(attrs, rider),
         {:ok, recipient_name} <- required_text(attrs, :recipient_name, :missing_recipient_name),
         {:ok, recipient_phone} <-
           required_phone(
             attrs,
             :recipient_phone,
             :missing_recipient_phone,
             :invalid_recipient_phone
           ),
         {:ok, recipient_user_id} <- ensure_recipient_has_app_account(recipient_phone),
         {:ok, item_description} <-
           required_text(attrs, :item_description, :missing_item_description),
         {:ok, send_policy} <- ProhibitedItems.evaluate(item_description),
         {:ok, item_size} <-
           required_enum(attrs, :item_size, @item_sizes, :missing_item_size, :invalid_item_size),
         {:ok, payer} <- required_enum(attrs, :payer, @payers, :missing_payer, :invalid_payer),
         {:ok, payment_timing} <-
           required_enum(
             attrs,
             :payment_timing,
             @payment_timings,
             :missing_payment_timing,
             :invalid_payment_timing
           ),
         :ok <- validate_send_payment_config(payer, payment_timing),
         {:ok, liability_acknowledged} <- liability_acknowledgement(attrs, send_policy.warnings),
         {:ok, item_value_kes} <- optional_non_negative_decimal(attrs, :item_value_kes) do
      {:ok,
       %{
         "sender_name" => sender_name,
         "sender_phone" => sender_phone,
         "recipient_name" => recipient_name,
         "recipient_phone" => recipient_phone,
         "recipient_user_id" => recipient_user_id,
         "item_description" => item_description,
         "item_size" => item_size,
         "payer" => payer,
         "payment_timing" => payment_timing,
         "liability_acknowledged" => liability_acknowledged,
         "prohibited_item_warnings" => send_policy.warnings,
         "item_value_kes" => item_value_kes,
         "special_instructions" =>
           attrs |> PaymentUtils.get_value(:special_instructions) |> PaymentUtils.normalize_text()
       }}
    end
  end

  defp fetch_rider(rider_user_id) do
    case Repo.get(User, rider_user_id) do
      %User{} = rider -> {:ok, rider}
      _ -> {:error, :rider_not_found}
    end
  end

  defp required_text(attrs, key, error) do
    case attrs |> PaymentUtils.get_value(key) |> PaymentUtils.normalize_text() do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  defp sender_phone(attrs, rider) do
    raw_phone =
      attrs
      |> PaymentUtils.get_value(:sender_phone)
      |> PaymentUtils.normalize_text()
      |> case do
        nil -> rider.phone |> PaymentUtils.normalize_text()
        value -> value
      end

    case raw_phone do
      nil -> {:error, :missing_sender_phone}
      value -> normalize_phone(value, :invalid_sender_phone)
    end
  end

  defp required_phone(attrs, key, missing_error, invalid_error) do
    case attrs |> PaymentUtils.get_value(key) |> PaymentUtils.normalize_text() do
      nil -> {:error, missing_error}
      value -> normalize_phone(value, invalid_error)
    end
  end

  defp ensure_recipient_has_app_account(recipient_phone) do
    case Repo.one(from u in User, where: u.phone == ^recipient_phone, select: u.id, limit: 1) do
      user_id when is_integer(user_id) -> {:ok, user_id}
      _ -> {:error, :recipient_app_account_required}
    end
  end

  defp normalize_phone(phone, invalid_error) do
    case Auth.normalize_identifier_for_method("phone_otp", phone) do
      {:ok, normalized} -> {:ok, normalized}
      _ -> {:error, invalid_error}
    end
  end

  defp optional_non_negative_decimal(attrs, key) do
    case attrs |> PaymentUtils.get_value(key) |> PaymentUtils.normalize_text() do
      nil ->
        {:ok, nil}

      value ->
        case parse_non_negative_decimal(value) do
          {:ok, decimal} -> {:ok, D.to_string(decimal, :normal)}
          {:error, _reason} -> {:error, :invalid_item_value_kes}
        end
    end
  end

  defp parse_non_negative_decimal(value) when is_binary(value) do
    case D.parse(String.trim(value)) do
      {decimal, ""} ->
        if D.compare(decimal, D.new("0")) in [:gt, :eq],
          do: {:ok, decimal},
          else: {:error, :invalid_decimal}

      _ ->
        {:error, :invalid_decimal}
    end
  end

  defp parse_non_negative_decimal(value) when is_integer(value) and value >= 0,
    do: {:ok, D.new(value)}

  defp parse_non_negative_decimal(value) when is_float(value) and value >= 0,
    do: {:ok, D.from_float(value)}

  defp parse_non_negative_decimal(_value), do: {:error, :invalid_decimal}

  defp required_enum(attrs, key, allowed_values, missing_error, invalid_error) do
    case attrs |> PaymentUtils.get_value(key) |> PaymentUtils.normalize_text() do
      nil ->
        {:error, missing_error}

      value ->
        normalized = String.downcase(value)

        if normalized in allowed_values do
          {:ok, normalized}
        else
          {:error, invalid_error}
        end
    end
  end

  defp validate_send_payment_config("recipient", "before"),
    do: {:error, :invalid_send_payment_config}

  defp validate_send_payment_config(_payer, _payment_timing), do: :ok

  defp liability_acknowledgement(attrs, warnings) do
    acknowledged = parse_bool(PaymentUtils.get_value(attrs, :liability_acknowledged), false)

    if warnings == [] or acknowledged do
      {:ok, acknowledged}
    else
      {:error, :send_liability_ack_required}
    end
  end

  defp parse_bool(value, default) do
    case value do
      value when value in [true, "true", "1", "yes", "on"] -> true
      value when value in [false, "false", "0", "no", "off"] -> false
      _ -> default
    end
  end

  defp resolve_limit(attrs) do
    attrs
    |> PaymentUtils.get_value(:limit)
    |> PaymentUtils.parse_integer(@default_history_limit)
    |> clamp_limit()
  end

  defp clamp_limit(value) when is_integer(value) and value < 1, do: @default_history_limit

  defp clamp_limit(value) when is_integer(value) and value > @max_history_limit,
    do: @max_history_limit

  defp clamp_limit(value) when is_integer(value), do: value
  defp clamp_limit(_value), do: @default_history_limit
end
