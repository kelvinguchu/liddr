defmodule LiddrWeb.SendDeliverySerializer do
  def delivery_payload(delivery) do
    %{
      ride_id: delivery.ride_id,
      sender_name: delivery.sender_name,
      sender_phone: delivery.sender_phone,
      recipient_name: delivery.recipient_name,
      recipient_phone: delivery.recipient_phone,
      item_description: delivery.item_description,
      item_size: delivery.item_size,
      payer: delivery.payer,
      payment_timing: delivery.payment_timing,
      item_value_kes: delivery.item_value_kes,
      special_instructions: delivery.special_instructions,
      liability_acknowledged: delivery.liability_acknowledged,
      prohibited_item_warnings: delivery.prohibited_item_warnings,
      pickup_proof_key: delivery.pickup_proof_key,
      pickup_proof_captured_at: delivery.pickup_proof_captured_at,
      dropoff_proof_key: delivery.dropoff_proof_key,
      dropoff_proof_captured_at: delivery.dropoff_proof_captured_at,
      recipient_confirmation_status: delivery.recipient_confirmation_status,
      recipient_confirmation_expires_at: delivery.recipient_confirmation_expires_at,
      recipient_confirmed_at: delivery.recipient_confirmed_at,
      delivery_status: delivery.delivery_status,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end
end
