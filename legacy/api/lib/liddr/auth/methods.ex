defmodule Liddr.Auth.Methods do
  @supported_methods [
    %{
      method: "phone_otp",
      label: "Phone OTP",
      allowed_for: ["rider", "driver"],
      requires_secret: false
    },
    %{
      method: "email_otp",
      label: "Email OTP",
      allowed_for: ["rider", "driver"],
      requires_secret: false
    },
    %{method: "google", label: "Google", allowed_for: ["rider"], requires_secret: true},
    %{method: "apple", label: "Apple", allowed_for: ["rider"], requires_secret: false},
    %{
      method: "totp",
      label: "Authenticator App",
      allowed_for: ["driver", "ops"],
      requires_secret: true
    }
  ]

  @registration_methods Enum.map(@supported_methods, & &1.method)
  @otp_methods ~w(phone_otp email_otp)
  @challenge_purposes ~w(login register_driver register_rider step_up recover_account reset_password)

  def supported_methods, do: @supported_methods
  def registration_methods, do: @registration_methods
  def challenge_purposes, do: @challenge_purposes

  def ensure_otp_provider(provider) do
    if provider in @otp_methods, do: :ok, else: {:error, :method_does_not_support_challenge}
  end

  def method_allowed_for_role?(method, role) do
    allowed_roles =
      @supported_methods
      |> Enum.find(&(&1.method == method))
      |> Map.get(:allowed_for, [])

    if role in allowed_roles do
      :ok
    else
      {:error, :method_not_allowed_for_role}
    end
  end

  def provider_to_channel("phone_otp"), do: "sms"
  def provider_to_channel("email_otp"), do: "email"
  def provider_to_channel("totp"), do: "totp"
  def provider_to_channel(_provider), do: "push"
end
