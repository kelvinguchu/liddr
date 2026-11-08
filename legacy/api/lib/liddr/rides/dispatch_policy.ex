defmodule Liddr.Rides.DispatchPolicy do
  @moduledoc false

  @eta_weight 0.7
  @rating_weight 0.3
  @eta_decay_m 1_000.0
  @eta_decay_seconds 240.0
  @new_user_min_rated_rides 10
  @new_driver_min_rated_rides @new_user_min_rated_rides
  @new_driver_neutral_rating_score 0.7
  @rating_tiebreak_distance_m 250
  @rating_tiebreak_eta_seconds 90

  def eta_weight, do: @eta_weight
  def rating_weight, do: @rating_weight
  def eta_decay_m, do: @eta_decay_m
  def eta_decay_seconds, do: @eta_decay_seconds
  def new_user_min_rated_rides, do: @new_user_min_rated_rides
  def new_driver_min_rated_rides, do: @new_driver_min_rated_rides
  def new_driver_neutral_rating_score, do: @new_driver_neutral_rating_score
  def rating_tiebreak_distance_m, do: @rating_tiebreak_distance_m
  def rating_tiebreak_eta_seconds, do: @rating_tiebreak_eta_seconds
end
