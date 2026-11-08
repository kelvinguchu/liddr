defmodule Liddr.TestSupport.GCSMetadataStub do
  def put_response(storage_key, response) when is_binary(storage_key) do
    responses =
      Process.get({__MODULE__, :responses}, %{})
      |> Map.put(storage_key, response)

    Process.put({__MODULE__, :responses}, responses)
    :ok
  end

  def reset do
    Process.delete({__MODULE__, :responses})
    :ok
  end

  def fetch_object_metadata(storage_key) when is_binary(storage_key) do
    responses = Process.get({__MODULE__, :responses}, %{})

    case Map.get(responses, storage_key) do
      nil -> {:error, :uploaded_file_not_found}
      response -> {:ok, response}
    end
  end
end
