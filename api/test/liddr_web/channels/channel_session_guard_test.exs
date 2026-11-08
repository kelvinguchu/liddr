defmodule LiddrWeb.ChannelSessionGuardTest do
  use Liddr.DataCase, async: false

  import Ecto.Query
  import Phoenix.ChannelTest

  alias Liddr.Accounts.User
  alias Liddr.Auth.AuthSession
  alias Liddr.Auth.Sessions
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures
  alias LiddrWeb.DriverChannel
  alias LiddrWeb.Endpoint
  alias LiddrWeb.UserSocket
  alias Phoenix.Socket.Broadcast

  @endpoint LiddrWeb.Endpoint

  test "a channel stays open while the session is valid" do
    %{channel: channel, disconnect_topic: topic} = joined_driver_channel()

    send(channel, :revalidate_session)
    _ = :sys.get_state(channel)

    assert Process.alive?(channel)
    refute_received %Broadcast{topic: ^topic, event: "disconnect"}
  end

  test "a channel stays open after its access token is rotated" do
    %{channel: channel, session_id: session_id, user_id: user_id} = joined_driver_channel()
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    session = Repo.get!(AuthSession, session_id)

    _replacement =
      Sessions.issue_session!(user_id, session.auth_method, now, %{}, session.session_family_id)

    session |> Ecto.Changeset.change(revoked_at: now, revoked_reason: "rotated") |> Repo.update!()

    send(channel, :revalidate_session)
    _ = :sys.get_state(channel)

    assert Process.alive?(channel)
  end

  test "a revoked session disconnects the socket" do
    %{channel: channel, disconnect_topic: topic, user_id: user_id} = joined_driver_channel()
    ref = Process.monitor(channel)
    revoke_sessions!(user_id)

    send(channel, :revalidate_session)

    assert_receive %Broadcast{topic: ^topic, event: "disconnect"}, 2_000
    assert_receive {:DOWN, ^ref, :process, ^channel, _reason}, 2_000
  end

  test "a suspended account disconnects the socket" do
    %{channel: channel, disconnect_topic: topic, user_id: user_id} = joined_driver_channel()
    suspend!(user_id)

    send(channel, :revalidate_session)

    assert_receive %Broadcast{topic: ^topic, event: "disconnect"}, 2_000
  end

  test "an open socket cannot join a topic after its session is revoked" do
    %{access_token: token, user_id: user_id} = AuthFixtures.authenticate_with_role!("driver")
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    revoke_sessions!(user_id)

    assert {:error, %{reason: "forbidden"}} =
             subscribe_and_join(socket, DriverChannel, "driver:#{user_id}")
  end

  defp joined_driver_channel do
    %{access_token: token, user_id: user_id} = AuthFixtures.authenticate_with_role!("driver")
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _reply, joined} = subscribe_and_join(socket, DriverChannel, "driver:#{user_id}")
    :ok = Endpoint.subscribe(joined.id)

    %{
      channel: joined.channel_pid,
      disconnect_topic: joined.id,
      session_id: joined.assigns.current_session_id,
      user_id: user_id
    }
  end

  defp revoke_sessions!(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.update_all(from(s in AuthSession, where: s.user_id == ^user_id),
      set: [revoked_at: now, revoked_reason: "logout"]
    )
  end

  defp suspend!(user_id) do
    Repo.get!(User, user_id)
    |> Ecto.Changeset.change(account_status: "suspended")
    |> Repo.update!()
  end
end
