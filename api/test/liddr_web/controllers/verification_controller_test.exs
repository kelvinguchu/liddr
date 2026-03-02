defmodule LiddrWeb.VerificationControllerTest do
  use LiddrWeb.ConnCase, async: true

  alias LiddrWeb.AuthFixtures
  alias Liddr.VerificationFixtures

  test "POST /api/verification/applications forbids non-driver roles", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_rider!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    assert %{"error" => %{"code" => "FORBIDDEN_ROLE"}} = json_response(conn, 403)
  end

  test "POST /api/verification/applications creates driver profile and active application", %{
    conn: conn
  } do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()

    conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id,
        "license_no" => "DL-TEST-001",
        "plate_no" => "KDA123A",
        "vehicle_year" => 2020
      })

    assert %{
             "data" => %{
               "driver" => %{
                 "account_status" => "pending",
                 "verification_status" => "pending",
                 "vehicle_category_id" => ^category_id
               },
               "application" => %{
                 "id" => application_id,
                 "status" => "pending",
                 "provider" => "internal"
               }
             }
           } = json_response(conn, 201)

    assert is_integer(application_id)
  end

  test "POST /api/verification/documents stores document and promotes application", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    requirement = VerificationFixtures.create_verification_requirement!("drivers_licence")

    app_conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    application_id = app_conn |> json_response(201) |> get_in(["data", "application", "id"])

    conn =
      post(auth_conn, "/api/verification/documents", %{
        "application_id" => application_id,
        "document_type" => requirement.document_type,
        "storage_key" => "verification/docs/licence-1.jpg",
        "file_mime" => "image/jpeg",
        "file_size_bytes" => 120_000
      })

    assert %{
             "data" => %{
               "application" => %{"id" => ^application_id, "status" => "under_review"},
               "document" => %{
                 "application_id" => ^application_id,
                 "document_type" => "drivers_licence",
                 "version" => 1,
                 "status" => "pending_review"
               }
             }
           } = json_response(conn, 201)
  end

  test "GET /api/verification/status returns missing required documents", %{conn: conn} do
    %{auth_conn: auth_conn} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    VerificationFixtures.create_verification_requirement!("national_id_front")
    VerificationFixtures.create_verification_requirement!("national_id_back")

    _ =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    conn = get(auth_conn, "/api/verification/status")

    assert %{
             "data" => %{
               "driver" => %{"verification_status" => "pending"},
               "application" => %{"status" => "pending"},
               "missing_required_document_types" => missing
             }
           } = json_response(conn, 200)

    assert Enum.sort(missing) == ["national_id_back", "national_id_front"]
  end
end
