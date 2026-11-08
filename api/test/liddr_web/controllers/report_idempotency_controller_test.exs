defmodule LiddrWeb.ReportIdempotencyControllerTest do
  use LiddrWeb.ConnCase, async: false

  import Ecto.Query

  alias Liddr.Accounts.User
  alias Liddr.Moderation.Report
  alias Liddr.Moderation.ReportCategory
  alias Liddr.Repo
  alias LiddrWeb.AuthFixtures

  test "POST /api/reports replays response for identical idempotency key", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: reporter_id} =
      AuthFixtures.authenticate_rider!(conn, "0711000101")

    reported = Repo.insert!(%User{phone: "254711001001"})
    insert_category!("unsafe_driving", "both", true, 10, 5)
    key = "report-create-#{System.unique_integer([:positive])}"
    description = "Unsafe lane changes #{System.unique_integer([:positive])}"

    first =
      auth_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => description
      })
      |> json_response(201)

    second =
      auth_conn
      |> recycle()
      |> put_req_header("idempotency-key", key)
      |> post("/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => description
      })
      |> json_response(201)

    assert get_in(first, ["data", "id"]) == get_in(second, ["data", "id"])

    count =
      Repo.one!(
        from r in Report,
          where: r.reporter_user_id == ^reporter_id and r.description == ^description,
          select: count(r.id)
      )

    assert count == 1
  end

  test "POST /api/reports rejects same idempotency key with different payload", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn, "0711000102")

    reported = Repo.insert!(%User{phone: "254711001002"})
    insert_category!("unsafe_driving", "both", true, 10, 5)
    key = "report-create-mismatch-#{System.unique_integer([:positive])}"

    _ =
      auth_conn
      |> put_req_header("idempotency-key", key)
      |> post("/api/reports", %{
        "reported_user_id" => reported.id,
        "category_slug" => "unsafe_driving",
        "description" => "Original report body"
      })
      |> json_response(201)

    assert %{"error" => %{"code" => "IDEMPOTENCY_KEY_REUSED"}} =
             auth_conn
             |> recycle()
             |> put_req_header("idempotency-key", key)
             |> post("/api/reports", %{
               "reported_user_id" => reported.id,
               "category_slug" => "unsafe_driving",
               "description" => "Changed report body"
             })
             |> json_response(409)
  end

  defp insert_category!(slug, applies_to, is_active, display_order, severity) do
    Repo.insert!(%ReportCategory{
      slug: slug,
      label: String.replace(slug, "_", " ") |> String.capitalize(),
      description: "Test category",
      applies_to: applies_to,
      severity_level_default: severity,
      recommended_action: "review",
      requires_immediate_attention: false,
      is_active: is_active,
      display_order: display_order
    })
  end
end
