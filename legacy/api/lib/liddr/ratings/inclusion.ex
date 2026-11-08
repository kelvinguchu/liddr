defmodule Liddr.Ratings.Inclusion do
  alias Liddr.Ratings.Policy

  def decision(score, reason_tags) when is_integer(score) and is_list(reason_tags) do
    has_non_attributable_tag =
      score < 5 and Enum.any?(reason_tags, &Policy.non_attributable_tag?/1)

    if has_non_attributable_tag do
      {false, "out_of_control_factor"}
    else
      {true, nil}
    end
  end
end
