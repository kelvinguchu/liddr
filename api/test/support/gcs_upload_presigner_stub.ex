defmodule Liddr.TestSupport.GCSUploadPresignerStub do
  def presign_put_upload(storage_key, content_type, _opts \\ []) do
    {:ok,
     %{
       upload_url: "https://example.test/upload/#{URI.encode_www_form(storage_key)}",
       required_headers: %{"content-type" => content_type},
       expires_at: ~U[2026-03-06 12:00:00Z],
       storage_key: storage_key,
       bucket: "test-verification-bucket"
     }}
  end
end
