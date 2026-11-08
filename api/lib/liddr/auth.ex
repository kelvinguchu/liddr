defmodule Liddr.Auth do
  alias Liddr.Auth.Challenges
  alias Liddr.Auth.Input
  alias Liddr.Auth.Methods
  alias Liddr.Auth.Registration
  alias Liddr.Auth.Sessions

  def supported_methods, do: Methods.supported_methods()

  def register_rider(attrs), do: Registration.register_user(attrs, "rider")
  def register_driver(attrs), do: Registration.register_user(attrs, "driver")

  def request_challenge(attrs, meta \\ %{}), do: Challenges.request_challenge(attrs, meta)
  def verify_challenge(attrs, meta \\ %{}), do: Challenges.verify_challenge(attrs, meta)

  def refresh_session(attrs, meta \\ %{}), do: Sessions.refresh_session(attrs, meta)
  def logout(attrs), do: Sessions.logout(attrs)

  defdelegate session_active?(session_id), to: Sessions

  def authenticate_access_token(access_token, meta \\ %{}),
    do: Sessions.authenticate_access_token(access_token, meta)

  def normalize_identifier_for_method(method, identifier) do
    Input.normalize_identifier_for_method(method, identifier)
  end
end
