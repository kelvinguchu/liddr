defmodule Liddr.Verification.Documents.ReviewInputTest do
  use ExUnit.Case, async: true

  alias Liddr.Verification.Documents.ReviewInput

  describe "fetch_document_review_decision/1" do
    test "accepts approve and reject decisions" do
      assert {:ok, "approve"} =
               ReviewInput.fetch_document_review_decision(%{"decision" => "approve"})

      assert {:ok, "reject"} = ReviewInput.fetch_document_review_decision(%{decision: "reject"})

      assert {:ok, "approve"} =
               ReviewInput.fetch_document_review_decision(%{"decision" => "  approve  "})
    end

    test "rejects unsupported decisions" do
      assert {:error, :invalid_document_review_decision} =
               ReviewInput.fetch_document_review_decision(%{"decision" => "invalid"})

      assert {:error, :invalid_document_review_decision} =
               ReviewInput.fetch_document_review_decision(%{})
    end
  end

  describe "parse_document_id/1" do
    test "accepts positive integer and numeric string ids" do
      assert {:ok, 7} = ReviewInput.parse_document_id(7)
      assert {:ok, 12} = ReviewInput.parse_document_id("12")
    end

    test "rejects invalid ids" do
      assert {:error, :document_not_found} = ReviewInput.parse_document_id(0)
      assert {:error, :document_not_found} = ReviewInput.parse_document_id(-1)
      assert {:error, :document_not_found} = ReviewInput.parse_document_id("abc")
      assert {:error, :document_not_found} = ReviewInput.parse_document_id(nil)
    end
  end

  describe "parse_document_ids/1" do
    test "accepts unique positive document ids" do
      assert {:ok, [1, 2, 3]} = ReviewInput.parse_document_ids([1, "2", 3])
    end

    test "rejects duplicates and invalid values" do
      assert {:error, :invalid_document_ids} = ReviewInput.parse_document_ids([1, 1])
      assert {:error, :invalid_document_ids} = ReviewInput.parse_document_ids([1, -2])
      assert {:error, :invalid_document_ids} = ReviewInput.parse_document_ids([1, "bad"])
      assert {:error, :invalid_document_ids} = ReviewInput.parse_document_ids([])
      assert {:error, :invalid_document_ids} = ReviewInput.parse_document_ids("1,2")
    end
  end
end
