ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Liddr.Repo, :manual)

# Keep verification tests deterministic even when shell .env enables these features.
System.put_env("MALWARE_SCAN_ENABLED", "false")
System.put_env("OCR_ENABLED", "false")
System.put_env("OCR_PDF_ENABLED", "false")
