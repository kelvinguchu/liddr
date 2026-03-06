defmodule LiddrWeb.VerificationControllerTest do
  use LiddrWeb.ConnCase, async: true

  alias LiddrWeb.AuthFixtures
  alias Liddr.TestSupport.GCSMetadataStub
  alias Liddr.TestSupport.GCSUploadPresignerStub
  alias Liddr.VerificationFixtures

  setup do
    original_metadata = Application.get_env(:liddr, :gcs_object_metadata_fetcher)
    original_presigner = Application.get_env(:liddr, :gcs_upload_presigner)
    Application.put_env(:liddr, :gcs_object_metadata_fetcher, GCSMetadataStub)
    Application.put_env(:liddr, :gcs_upload_presigner, GCSUploadPresignerStub)
    GCSMetadataStub.reset()

    on_exit(fn ->
      GCSMetadataStub.reset()

      if is_nil(original_metadata) do
        Application.delete_env(:liddr, :gcs_object_metadata_fetcher)
      else
        Application.put_env(:liddr, :gcs_object_metadata_fetcher, original_metadata)
      end

      if is_nil(original_presigner) do
        Application.delete_env(:liddr, :gcs_upload_presigner)
      else
        Application.put_env(:liddr, :gcs_upload_presigner, original_presigner)
      end
    end)

    :ok
  end

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
    %{auth_conn: auth_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    requirement = VerificationFixtures.create_verification_requirement!("drivers_licence")

    app_conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    application_id = app_conn |> json_response(201) |> get_in(["data", "application", "id"])

    storage_key = "verification/docs/#{driver_user_id}/drivers_licence/licence-1.jpg"

    :ok =
      GCSMetadataStub.put_response(storage_key, %{
        content_type: "image/jpeg",
        file_size_bytes: 120_000,
        generation: "1",
        etag: "etag-1",
        md5_hash: "abc",
        crc32c: "crc"
      })

    conn =
      post(auth_conn, "/api/verification/documents", %{
        "application_id" => application_id,
        "document_type" => requirement.document_type,
        "storage_key" => storage_key,
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

  test "POST /api/verification/documents rejects another driver's storage key", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    requirement = VerificationFixtures.create_verification_requirement!("drivers_licence")

    app_conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    application_id = app_conn |> json_response(201) |> get_in(["data", "application", "id"])

    other_driver_id = driver_user_id + 999

    conn =
      post(auth_conn, "/api/verification/documents", %{
        "application_id" => application_id,
        "document_type" => requirement.document_type,
        "storage_key" => "verification/docs/#{other_driver_id}/drivers_licence/licence-1.jpg",
        "file_mime" => "image/jpeg",
        "file_size_bytes" => 120_000
      })

    assert %{"error" => %{"code" => "INVALID_STORAGE_KEY"}} = json_response(conn, 422)
  end

  test "POST /api/verification/documents rejects mismatched uploaded object metadata", %{
    conn: conn
  } do
    %{auth_conn: auth_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    category_id = VerificationFixtures.insert_vehicle_category!()
    requirement = VerificationFixtures.create_verification_requirement!("drivers_licence")

    app_conn =
      post(auth_conn, "/api/verification/applications", %{
        "vehicle_category_id" => category_id
      })

    application_id = app_conn |> json_response(201) |> get_in(["data", "application", "id"])
    storage_key = "verification/docs/#{driver_user_id}/drivers_licence/licence-2.jpg"

    :ok =
      GCSMetadataStub.put_response(storage_key, %{
        content_type: "image/png",
        file_size_bytes: 120_000,
        generation: "2",
        etag: "etag-2",
        md5_hash: "def",
        crc32c: "crc2"
      })

    conn =
      post(auth_conn, "/api/verification/documents", %{
        "application_id" => application_id,
        "document_type" => requirement.document_type,
        "storage_key" => storage_key,
        "file_mime" => "image/jpeg",
        "file_size_bytes" => 120_000
      })

    assert %{"error" => %{"code" => "UPLOADED_FILE_MIME_MISMATCH"}} = json_response(conn, 422)
  end

  test "POST /api/verification/uploads/presign returns a scoped storage key", %{conn: conn} do
    %{auth_conn: auth_conn, user_id: driver_user_id} = AuthFixtures.authenticate_driver!(conn)
    _category_id = VerificationFixtures.insert_vehicle_category!()
    requirement = VerificationFixtures.create_verification_requirement!("drivers_licence")

    conn =
      post(auth_conn, "/api/verification/uploads/presign", %{
        "document_type" => requirement.document_type,
        "file_mime" => "image/jpeg",
        "file_size_bytes" => 120_000
      })

    assert %{
             "data" => %{
               "document_type" => "drivers_licence",
               "storage_key" => storage_key,
               "upload_url" => upload_url,
               "required_headers" => %{"content-type" => "image/jpeg"}
             }
           } = json_response(conn, 201)

    assert String.starts_with?(
             storage_key,
             "verification/docs/#{driver_user_id}/drivers_licence/"
           )

    assert String.contains?(upload_url, URI.encode_www_form(storage_key))
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
